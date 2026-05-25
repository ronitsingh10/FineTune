// FineTuneLoopback/FTLoopbackDriver.cpp
//
// CoreAudio AudioServerPlugIn implementation for the FineTune Loopback virtual device.
// Creates a virtual input device that reads audio from POSIX shared memory.
//
// Architecture:
//   - Static object model: PlugIn → Device → Stream (fixed IDs, no dynamic creation)
//   - IO reads from shared memory ring buffer written by FineTune app
//   - When FineTune is not connected, outputs silence
//
// Reference: Apple's NullAudio sample driver (simplified)

#include "FTLoopbackDriver.h"
#include "SharedTypes.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <os/log.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <atomic>
#include <syslog.h>

// ============================================================================
// MARK: - Globals
// ============================================================================

static os_log_t sLog = NULL;

// The host interface passed to us by CoreAudio
static AudioServerPlugInHostRef sHost = NULL;

// Driver state
static std::atomic<UInt32> sRefCount{0};
static Float64 sSampleRate = kFTDefaultSampleRate;
static UInt32 sBufferFrameSize = kFTDefaultBufferFrames;
static Float32 sVolumeLevel = 1.0f;
static bool sMuteState = false;

// IO state (following BlackHole's proven pattern)
static UInt64 gDevice_IOIsRunning = 0;
static pthread_mutex_t gDevice_IOMutex = PTHREAD_MUTEX_INITIALIZER;

// Zero timestamp tracking — period must be independent of IO buffer size
static const UInt32 kFTZeroTimeStampPeriod = 16384;
static Float64 gDevice_HostTicksPerFrame = 0.0;
static UInt64 gDevice_AnchorHostTime = 0;
static Float64 gDevice_PreviousTicks = 0.0;
static UInt64 gDevice_NumberTimeStamps = 0;

// Shared memory
static int sShmFD = -1;
static FTLoopbackSharedHeader* sShmHeader = NULL;
static float* sShmAudioData = NULL;
static size_t sShmSize = 0;

// Timing
static mach_timebase_info_data_t sTimebaseInfo = {0, 0};

static inline UInt64 HostTimeToNanos(UInt64 hostTime) {
    if (sTimebaseInfo.denom == 0) mach_timebase_info(&sTimebaseInfo);
    return hostTime * sTimebaseInfo.numer / sTimebaseInfo.denom;
}

static inline UInt64 NanosToHostTime(UInt64 nanos) {
    if (sTimebaseInfo.denom == 0) mach_timebase_info(&sTimebaseInfo);
    return nanos * sTimebaseInfo.denom / sTimebaseInfo.numer;
}

// ============================================================================
// MARK: - Shared Memory Helpers
// ============================================================================

static void OpenSharedMemory() {
    if (sShmHeader != NULL) return; // Already open

    int fd = shm_open(kFTLoopbackShmName, O_RDWR, 0);
    if (fd < 0) {
        // FineTune app hasn't created the shm yet — this is normal at startup
        return;
    }

    // Read the header first to get buffer dimensions
    // We'll map the minimum header size first, then remap with full size
    size_t headerSize = sizeof(FTLoopbackSharedHeader);
    void* headerMap = mmap(NULL, headerSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (headerMap == MAP_FAILED) {
        close(fd);
        return;
    }

    FTLoopbackSharedHeader* hdr = (FTLoopbackSharedHeader*)headerMap;
    uint32_t bufFrames = hdr->bufferFrames;
    uint32_t channels = hdr->channels;
    munmap(headerMap, headerSize);

    if (bufFrames == 0 || channels == 0) {
        close(fd);
        return;
    }

    // Now map the full region
    size_t fullSize = FTLoopbackShmSize(bufFrames, channels);
    void* fullMap = mmap(NULL, fullSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fullMap == MAP_FAILED) {
        close(fd);
        return;
    }

    sShmFD = fd;
    sShmHeader = (FTLoopbackSharedHeader*)fullMap;
    sShmAudioData = FTLoopbackAudioData(sShmHeader);
    sShmSize = fullSize;

    os_log_info(sLog, "Shared memory opened: %u frames, %u channels, %.0f Hz",
                bufFrames, channels, sShmHeader->sampleRate);
}

static void CloseSharedMemory() {
    if (sShmHeader != NULL) {
        munmap(sShmHeader, sShmSize);
        sShmHeader = NULL;
        sShmAudioData = NULL;
        sShmSize = 0;
    }
    if (sShmFD >= 0) {
        close(sShmFD);
        sShmFD = -1;
    }
}

/// Read frames from the shared memory ring buffer into the output buffer.
/// Returns the number of frames actually read (may be less than requested on underflow).
static UInt32 ReadFromRingBuffer(float* outBuffer, UInt32 framesToRead, UInt32 channels) {
    if (sShmHeader == NULL || sShmAudioData == NULL) return 0;

    // Check if producer is active
    uint32_t isActive = __atomic_load_n(&sShmHeader->isActive, __ATOMIC_ACQUIRE);
    if (!isActive) return 0;

    uint32_t bufFrames = sShmHeader->bufferFrames;
    uint32_t shmChannels = sShmHeader->channels;
    if (bufFrames == 0 || shmChannels == 0) return 0;

    uint64_t writeHead = __atomic_load_n(&sShmHeader->writeHead, __ATOMIC_ACQUIRE);
    uint64_t readHead = __atomic_load_n(&sShmHeader->readHead, __ATOMIC_RELAXED);

    // Available frames = writeHead - readHead
    int64_t available = (int64_t)(writeHead - readHead);
    if (available <= 0) return 0;

    UInt32 framesToCopy = (UInt32)((available < (int64_t)framesToRead) ? available : framesToRead);
    UInt32 minChannels = (channels < shmChannels) ? channels : shmChannels;

    for (UInt32 frame = 0; frame < framesToCopy; frame++) {
        UInt32 ringPos = (UInt32)((readHead + frame) % bufFrames);
        UInt32 outPos = frame * channels;
        UInt32 shmPos = ringPos * shmChannels;

        for (UInt32 ch = 0; ch < minChannels; ch++) {
            outBuffer[outPos + ch] = sShmAudioData[shmPos + ch];
        }
        // Zero extra output channels
        for (UInt32 ch = minChannels; ch < channels; ch++) {
            outBuffer[outPos + ch] = 0.0f;
        }
    }

    // Update read head
    __atomic_store_n(&sShmHeader->readHead, readHead + framesToCopy, __ATOMIC_RELEASE);

    return framesToCopy;
}

// ============================================================================
// MARK: - AudioServerPlugInDriverInterface Implementation
// ============================================================================

// Forward declarations
static HRESULT FT_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG FT_AddRef(void* inDriver);
static ULONG FT_Release(void* inDriver);
static OSStatus FT_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus FT_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus FT_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus FT_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus FT_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus FT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo);
static OSStatus FT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void* inChangeInfo);
static Boolean FT_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                              const AudioObjectPropertyAddress* inAddress);
static OSStatus FT_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                      const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus FT_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                        const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                        const void* inQualifierData, UInt32* outDataSize);
static OSStatus FT_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus FT_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus FT_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus FT_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus FT_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus FT_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outIsInput);
static OSStatus FT_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus FT_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus FT_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// The vtable
static AudioServerPlugInDriverInterface sDriverInterface = {
    NULL, // _reserved
    FT_QueryInterface,
    FT_AddRef,
    FT_Release,
    FT_Initialize,
    FT_CreateDevice,
    FT_DestroyDevice,
    FT_AddDeviceClient,
    FT_RemoveDeviceClient,
    FT_PerformDeviceConfigurationChange,
    FT_AbortDeviceConfigurationChange,
    FT_HasProperty,
    FT_IsPropertySettable,
    FT_GetPropertyDataSize,
    FT_GetPropertyData,
    FT_SetPropertyData,
    FT_StartIO,
    FT_StopIO,
    FT_GetZeroTimeStamp,
    FT_WillDoIOOperation,
    FT_BeginIOOperation,
    FT_DoIOOperation,
    FT_EndIOOperation,
};

static AudioServerPlugInDriverInterface* sDriverInterfacePtr = &sDriverInterface;

// ============================================================================
// MARK: - IUnknown
// ============================================================================

static HRESULT FT_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    // The UUIDs we need to match
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    
    // IUnknown UUID
    CFUUIDRef iunknownUUID = CFUUIDGetConstantUUIDWithBytes(NULL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
    
    // AudioServerPlugInDriverInterface UUID (this is what coreaudiod queries with!)
    CFUUIDRef driverInterfaceUUID = kAudioServerPlugInDriverInterfaceUUID;

    HRESULT result = E_NOINTERFACE;

    if (CFEqual(requestedUUID, iunknownUUID) || CFEqual(requestedUUID, driverInterfaceUUID)) {
        FT_AddRef(inDriver);
        *outInterface = &sDriverInterfacePtr;
        result = S_OK;
    }

    CFRelease(requestedUUID);
    return result;
}

static ULONG FT_AddRef(void* inDriver) {
    return ++sRefCount;
}

static ULONG FT_Release(void* inDriver) {
    UInt32 count = --sRefCount;
    if (count == 0) {
        CloseSharedMemory();
    }
    return count;
}

// ============================================================================
// MARK: - Initialization
// ============================================================================

static OSStatus FT_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    sHost = inHost;
    sLog = os_log_create("com.finetuneapp.FineTuneLoopback", "Driver");
    mach_timebase_info(&sTimebaseInfo);

    FILE* f = fopen("/tmp/ftloopback_init.txt", "w");
    if (f) { fprintf(f, "Initialize called. Host=%p\n", inHost); fclose(f); }
    syslog(LOG_ERR, "FTLoopback: Initialize called! Driver is loaded.");
    os_log_info(sLog, "FineTune Loopback driver initialized");
    return kAudioHardwareNoError;
}

static OSStatus FT_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    // Our device is created statically — nothing to do
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FT_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FT_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo* inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus FT_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus FT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

static OSStatus FT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void* inChangeInfo) {
    return kAudioHardwareNoError;
}

// ============================================================================
// MARK: - Property Support: HasProperty
// ============================================================================

static Boolean FT_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                              const AudioObjectPropertyAddress* inAddress) {
    switch (inObjectID) {

    // --- Plugin ---
    case kFTObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        break;

    // --- Device ---
    case kFTObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyIsHidden:
        case kAudioObjectPropertyElementName:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioObjectPropertyControlList:
            return true;
        }
        break;

    // --- Stream ---
    case kFTObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        case kAudioStreamPropertyIsActive:
            return true;
        }
        break;

    // --- Volume Control ---
    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyElementName:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioObjectPropertyScopeGlobal:
            return true;
        }
        break;
    }

    return false;
}

// ============================================================================
// MARK: - Property Support: IsPropertySettable
// ============================================================================

static OSStatus FT_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                      const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    *outIsSettable = false;

    switch (inObjectID) {
    case kFTObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyBufferFrameSize:
            *outIsSettable = true;
            break;
        }
        break;

    case kFTObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        }
        break;

    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
            *outIsSettable = true;
            break;
        }
        break;
    }

    return kAudioHardwareNoError;
}

// ============================================================================
// MARK: - Property Support: GetPropertyDataSize
// ============================================================================

static OSStatus FT_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                        const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                        const void* inQualifierData, UInt32* outDataSize) {

    switch (inObjectID) {

    // --- Plugin ---
    case kFTObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID); // 1 device
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        break;

    // --- Device ---
    case kFTObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            // stream + volume control
            *outDataSize = 2 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyElementName:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyClockIsStable:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyClockAlgorithm:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *outDataSize = sizeof(AudioObjectID); // 1 stream
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(kFTNumSampleRates * sizeof(AudioValueRange));
            return kAudioHardwareNoError;
        case kAudioDevicePropertyBufferFrameSizeRange:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyIcon:
            *outDataSize = sizeof(CFURLRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = sizeof(AudioObjectID); // 1 control (volume)
            return kAudioHardwareNoError;
        }
        break;

    // --- Stream ---
    case kFTObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyIsActive:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(kFTNumSampleRates * sizeof(AudioStreamRangedDescription));
            return kAudioHardwareNoError;
        }
        break;

    // --- Volume ---
    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyElementName:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelValue:
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// ============================================================================
// MARK: - Property Support: GetPropertyData
// ============================================================================

static OSStatus FT_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {

    switch (inObjectID) {

    // ==== Plugin Properties ====
    case kFTObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *((AudioObjectID*)outData) = kFTObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kFTLoopbackManufacturer);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyResourceBundle:
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = *((CFStringRef*)inQualifierData);
            if (CFStringCompare(uid, CFSTR(kFTLoopbackDeviceUID), 0) == kCFCompareEqualTo) {
                *((AudioObjectID*)outData) = kFTObjectID_Device;
            } else {
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        }
        break;

    // ==== Device Properties ====
    case kFTObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kFTObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            UInt32 count = 0;
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
                inAddress->mScope == kAudioObjectPropertyScopeInput) {
                ids[count++] = kFTObjectID_Stream;
            }
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                ids[count++] = kFTObjectID_Volume;
            }
            *outDataSize = count * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioObjectPropertyName:
            *((CFStringRef*)outData) = CFSTR(kFTLoopbackDeviceName);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kFTLoopbackManufacturer);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyElementName:
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceUID:
            *((CFStringRef*)outData) = CFSTR(kFTLoopbackDeviceUID);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyModelUID:
            *((CFStringRef*)outData) = CFSTR(kFTLoopbackDeviceModelUID);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyTransportType:
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // Input device CAN be default input (so DAWs can find it)
            *((UInt32*)outData) = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *((UInt32*)outData) = 0; // Not suitable as system default
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyStreams: {
            if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                *((AudioObjectID*)outData) = kFTObjectID_Stream;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0; // No output streams
            }
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyNominalSampleRate:
            *((Float64*)outData) = sSampleRate;
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange* ranges = (AudioValueRange*)outData;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                ranges[i].mMinimum = kFTSupportedSampleRates[i];
                ranges[i].mMaximum = kFTSupportedSampleRates[i];
            }
            *outDataSize = (UInt32)(kFTNumSampleRates * sizeof(AudioValueRange));
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyLatency:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertySafetyOffset:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyClockDomain:
            *((UInt32*)outData) = kFTClockDomain;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsAlive:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceIsRunning:
            *((UInt32*)outData) = (gDevice_IOIsRunning > 0) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyIsHidden:
            *((UInt32*)outData) = 0; // Visible in device pickers
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyClockIsStable:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyClockAlgorithm:
            *((UInt32*)outData) = kAudioDeviceClockAlgorithmSimpleIIR;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyBufferFrameSize:
            *((UInt32*)outData) = sBufferFrameSize;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = kFTMinBufferFrames;
            range->mMaximum = kFTMaxBufferFrames;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyZeroTimeStampPeriod:
            *((UInt32*)outData) = kFTZeroTimeStampPeriod;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyRelatedDevices:
            *((AudioObjectID*)outData) = kFTObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyIcon:
            *((CFURLRef*)outData) = NULL;
            *outDataSize = sizeof(CFURLRef);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyControlList:
            *((AudioObjectID*)outData) = kFTObjectID_Volume;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        break;

    // ==== Stream Properties ====
    case kFTObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kFTObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyDirection:
            // 1 = input (this is an input stream — DAWs record FROM it)
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyTerminalType:
            *((UInt32*)outData) = kAudioStreamTerminalTypeLine;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyStartingChannel:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyLatency:
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyIsActive:
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription* desc = (AudioStreamBasicDescription*)outData;
            desc->mSampleRate = sSampleRate;
            desc->mFormatID = kAudioFormatLinearPCM;
            desc->mFormatFlags = kAudioFormatFlagIsFloat |
                                 kAudioFormatFlagsNativeEndian |
                                 kAudioFormatFlagIsPacked;
            desc->mBytesPerPacket = kFTChannelCount * sizeof(Float32);
            desc->mFramesPerPacket = 1;
            desc->mBytesPerFrame = kFTChannelCount * sizeof(Float32);
            desc->mChannelsPerFrame = kFTChannelCount;
            desc->mBitsPerChannel = 32;
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                descs[i].mFormat.mSampleRate = kFTSupportedSampleRates[i];
                descs[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                descs[i].mFormat.mFormatFlags = kAudioFormatFlagIsFloat |
                                                 kAudioFormatFlagsNativeEndian |
                                                 kAudioFormatFlagIsPacked;
                descs[i].mFormat.mBytesPerPacket = kFTChannelCount * sizeof(Float32);
                descs[i].mFormat.mFramesPerPacket = 1;
                descs[i].mFormat.mBytesPerFrame = kFTChannelCount * sizeof(Float32);
                descs[i].mFormat.mChannelsPerFrame = kFTChannelCount;
                descs[i].mFormat.mBitsPerChannel = 32;
                descs[i].mSampleRateRange.mMinimum = kFTSupportedSampleRates[i];
                descs[i].mSampleRateRange.mMaximum = kFTSupportedSampleRates[i];
            }
            *outDataSize = (UInt32)(kFTNumSampleRates * sizeof(AudioStreamRangedDescription));
            return kAudioHardwareNoError;
        }
        }
        break;

    // ==== Volume Control ====
    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioLevelControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kFTObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyElementName:
            *((CFStringRef*)outData) = CFSTR("Volume");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioLevelControlPropertyScalarValue:
            *((Float32*)outData) = sVolumeLevel;
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;

        case kAudioLevelControlPropertyDecibelValue:
            // Simple linear-to-dB: 20*log10(volume). Clamp to -96dB for zero.
            *((Float32*)outData) = (sVolumeLevel > 0.0001f)
                ? (Float32)(20.0 * log10((double)sVolumeLevel))
                : -96.0f;
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;

        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = -96.0;
            range->mMaximum = 0.0;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        }
        break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// ============================================================================
// MARK: - Property Support: SetPropertyData
// ============================================================================

static OSStatus FT_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, const void* inData) {

    switch (inObjectID) {
    case kFTObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 newRate = *((const Float64*)inData);
            // Validate it's a supported rate
            bool valid = false;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                if (kFTSupportedSampleRates[i] == newRate) { valid = true; break; }
            }
            if (!valid) return kAudioHardwareIllegalOperationError;
            sSampleRate = newRate;
            os_log_info(sLog, "Sample rate changed to %.0f", newRate);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyBufferFrameSize: {
            UInt32 newSize = *((const UInt32*)inData);
            if (newSize < kFTMinBufferFrames || newSize > kFTMaxBufferFrames)
                return kAudioHardwareIllegalOperationError;
            sBufferFrameSize = newSize;
            os_log_info(sLog, "Buffer frame size changed to %u", newSize);
            return kAudioHardwareNoError;
        }
        }
        break;

    case kFTObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            const AudioStreamBasicDescription* desc = (const AudioStreamBasicDescription*)inData;
            // Only allow changing sample rate, everything else is fixed
            bool validRate = false;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                if (kFTSupportedSampleRates[i] == desc->mSampleRate) { validRate = true; break; }
            }
            if (!validRate) return kAudioHardwareIllegalOperationError;
            sSampleRate = desc->mSampleRate;
            return kAudioHardwareNoError;
        }
        }
        break;

    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue: {
            Float32 val = *((const Float32*)inData);
            sVolumeLevel = (val < 0.0f) ? 0.0f : ((val > 1.0f) ? 1.0f : val);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyDecibelValue: {
            Float32 dB = *((const Float32*)inData);
            sVolumeLevel = (Float32)pow(10.0, (double)dB / 20.0);
            if (sVolumeLevel > 1.0f) sVolumeLevel = 1.0f;
            if (sVolumeLevel < 0.0f) sVolumeLevel = 0.0f;
            return kAudioHardwareNoError;
        }
        }
        break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// ============================================================================
// MARK: - IO Operations
// ============================================================================

static OSStatus FT_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    os_log_info(sLog, "StartIO: client=%u", inClientID);

    // Try to open shared memory when IO starts
    OpenSharedMemory();

    pthread_mutex_lock(&gDevice_IOMutex);
    
    if (gDevice_IOIsRunning == 0) {
        // First client starting IO — initialize timing anchor
        // Compute host ticks per frame from the host clock frequency
        Float64 theHostClockFrequency = 0.0;
        mach_timebase_info_data_t tbInfo;
        mach_timebase_info(&tbInfo);
        theHostClockFrequency = (Float64)tbInfo.denom / (Float64)tbInfo.numer * 1000000000.0;
        gDevice_HostTicksPerFrame = theHostClockFrequency / sSampleRate;
        
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        gDevice_PreviousTicks = 0.0;
    }
    
    gDevice_IOIsRunning += 1;
    
    pthread_mutex_unlock(&gDevice_IOMutex);
    return kAudioHardwareNoError;
}

static OSStatus FT_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    os_log_info(sLog, "StopIO: client=%u", inClientID);
    
    pthread_mutex_lock(&gDevice_IOMutex);
    if (gDevice_IOIsRunning > 0) {
        gDevice_IOIsRunning -= 1;
    }
    pthread_mutex_unlock(&gDevice_IOMutex);
    
    return kAudioHardwareNoError;
}

static OSStatus FT_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    // Following BlackHole's proven pattern:
    // The zero time stamps are spaced kFTZeroTimeStampPeriod frames apart.
    // We only advance the counter when the next timestamp's host time has passed.
    
    pthread_mutex_lock(&gDevice_IOMutex);
    
    UInt64 theCurrentHostTime = mach_absolute_time();
    
    // Calculate host ticks for one zero-timestamp period
    Float64 theHostTicksPerPeriod = gDevice_HostTicksPerFrame * (Float64)kFTZeroTimeStampPeriod;
    
    // Calculate the next timestamp offset
    Float64 theNextTickOffset = gDevice_PreviousTicks + theHostTicksPerPeriod;
    UInt64 theNextHostTime = gDevice_AnchorHostTime + (UInt64)theNextTickOffset;
    
    // Advance the counter if the next timestamp is in the past
    if (theNextHostTime <= theCurrentHostTime) {
        ++gDevice_NumberTimeStamps;
        gDevice_PreviousTicks = theNextTickOffset;
    }
    
    // Set the return values
    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kFTZeroTimeStampPeriod);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)gDevice_PreviousTicks;
    *outSeed = 1;
    
    pthread_mutex_unlock(&gDevice_IOMutex);
    
    return kAudioHardwareNoError;
}

static OSStatus FT_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outWillDoInPlace) {
    // We only do ReadInput (in place)
    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
        *outWillDo = true;
        *outWillDoInPlace = true;
        break;
    default:
        *outWillDo = false;
        *outWillDoInPlace = true;
        break;
    }
    return kAudioHardwareNoError;
}

static OSStatus FT_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus FT_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer) {

    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareNoError;
    }

    float* outBuffer = (float*)ioMainBuffer;
    UInt32 totalSamples = inIOBufferFrameSize * kFTChannelCount;

    // SAFETY: Always zero the entire buffer first to guarantee silence
    // if anything goes wrong below.
    memset(outBuffer, 0, totalSamples * sizeof(float));

    // Try to connect to shared memory if not already
    if (sShmHeader == NULL) {
        OpenSharedMemory();
    }

    // Read from ring buffer (overwrites zeroed buffer with real audio if available)
    UInt32 framesRead = ReadFromRingBuffer(outBuffer, inIOBufferFrameSize, kFTChannelCount);

    // Apply volume (only if we got real data and volume is reduced)
    if (framesRead > 0 && sVolumeLevel < 0.999f) {
        UInt32 samplesToScale = framesRead * kFTChannelCount;
        for (UInt32 i = 0; i < samplesToScale; i++) {
            outBuffer[i] *= sVolumeLevel;
        }
    }

    return kAudioHardwareNoError;
}

static OSStatus FT_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

// ============================================================================
// MARK: - Plugin Factory (Entry Point)
// ============================================================================

extern "C" void* FTLoopbackDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    // Verify this is the AudioServerPlugIn type
    CFUUIDRef pluginTypeUUID = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    if (!CFEqual(requestedTypeUUID, pluginTypeUUID)) {
        CFRelease(pluginTypeUUID);
        return NULL;
    }
    CFRelease(pluginTypeUUID);

    syslog(LOG_ERR, "FTLoopback: Factory called successfully, returning driver interface");
    // Debug: write a marker file to confirm factory was called
    FILE* f = fopen("/tmp/ftloopback_factory_called.txt", "w");
    if (f) { fprintf(f, "Factory called at %lu\n", (unsigned long)time(NULL)); fclose(f); }
    FT_AddRef(NULL);
    return &sDriverInterfacePtr;
}

// FineTuneLoopback/FTLoopbackDriver.cpp
//
// CoreAudio AudioServerPlugIn — FineTune Loopback Virtual Audio Cable
//
// Architecture:
//   Bidirectional virtual device: apps output TO the device, other apps record
//   FROM it. Internally routes output→input via a lock-free ring buffer.
//   No shared memory, no aggregate device — pure memcpy in coreaudiod's process.
//
//   This is the same architecture as BlackHole / Rogue Amoeba ACE.
//   Result: truly lossless recording immune to CPU spikes.
//
// Object model:
//   PlugIn (1) → Device (2) → Stream_Input (3)   [direction=1, DAWs read]
//                            → Volume (4)
//                            → Stream_Output (5)  [direction=0, apps write]

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
static AudioServerPlugInHostRef sHost = NULL;

static std::atomic<UInt32> sRefCount{0};
static Float64 sSampleRate = kFTDefaultSampleRate;
static UInt32 sBufferFrameSize = kFTDefaultBufferFrames;
static Float32 sVolumeLevel = 1.0f;

// IO state
static UInt64 gDevice_IOIsRunning = 0;
static pthread_mutex_t gDevice_IOMutex = PTHREAD_MUTEX_INITIALIZER;

// Zero timestamp tracking (lock-free for RT safety)
// These are accessed from the RT IO thread via GetZeroTimeStamp,
// so they must NOT be behind a mutex. StartIO/StopIO write them
// under gDevice_IOMutex, but GetZeroTimeStamp reads/updates
// them lock-free. This is safe because:
//   - GetZeroTimeStamp is the ONLY reader/writer on the RT thread
//   - StartIO resets them to 0 before IO begins (no concurrent readers)
// L2: 16384 doesn't divide 44100 evenly, but Float64 arithmetic in
// gDevice_PreviousTicks accumulates fractional ticks, so the clock
// stays accurate. Using a power-of-two avoids expensive divisions.
static const UInt32 kFTZeroTimeStampPeriod = 16384;
static Float64 gDevice_HostTicksPerFrame = 0.0;
static UInt64 gDevice_AnchorHostTime = 0;
static Float64 gDevice_PreviousTicks = 0.0;
static UInt64 gDevice_NumberTimeStamps = 0;

// Timing
static mach_timebase_info_data_t sTimebaseInfo = {0, 0};

// ============================================================================
// MARK: - Direct Passthrough Buffer (Virtual Audio Cable)
// ============================================================================
//
// Zero-latency approach: a flat buffer shared between WriteMix and ReadInput.
// WriteMix copies audio IN, ReadInput copies audio OUT — same IO cycle,
// same memory, no ring, no heads, no atomics. This is exactly how BlackHole
// achieves zero additional latency.
//
// If WriteMix runs before ReadInput in the cycle → true zero latency.
// If ReadInput runs first → reads previous cycle's data (1 cycle = 64 frames = 1.45ms).

static float sPassthroughBuffer[kFTMaxBufferFrames * kFTChannelCount];
static std::atomic<UInt32> sPassthroughFrameCount{0};  // atomic: written by WriteMix, read by ReadInput

// ============================================================================
// MARK: - Shared Memory Helpers (Legacy fallback)
// ============================================================================
// Kept for backward compatibility: when FineTune app writes processed audio
// via shared memory, the input stream can still read it. The internal ring
// buffer (from output stream writes) takes priority.

static int sShmFD = -1;
static FTLoopbackSharedHeader* sShmHeader = NULL;
static float* sShmAudioData = NULL;
static size_t sShmSize = 0;
static uint64_t sShmRetryHostTime = 0;
static const uint64_t kShmRetryCooldownNs = 500000000ULL;

static inline UInt64 NanosToHostTime(UInt64 nanos) {
    if (sTimebaseInfo.denom == 0) mach_timebase_info(&sTimebaseInfo);
    return nanos * sTimebaseInfo.denom / sTimebaseInfo.numer;
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

static void OpenSharedMemory() {
    if (sShmHeader != NULL) return;

    uint64_t now = mach_absolute_time();
    if (now < sShmRetryHostTime) return;

    int fd = shm_open(kFTLoopbackShmName, O_RDWR, 0);
    if (fd < 0) {
        sShmRetryHostTime = now + NanosToHostTime(kShmRetryCooldownNs);
        return;
    }

    FTLoopbackSharedHeader tempHeader;
    ssize_t bytesRead = read(fd, &tempHeader, sizeof(tempHeader));
    if (bytesRead < (ssize_t)sizeof(tempHeader) ||
        tempHeader.bufferFrames == 0 ||
        tempHeader.channels == 0) {
        close(fd);
        sShmRetryHostTime = now + NanosToHostTime(kShmRetryCooldownNs);
        return;
    }

    size_t totalSize = sizeof(FTLoopbackSharedHeader) +
                       (size_t)tempHeader.bufferFrames * tempHeader.channels * sizeof(float);

    void* mapped = mmap(NULL, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        close(fd);
        sShmRetryHostTime = now + NanosToHostTime(kShmRetryCooldownNs);
        return;
    }

    sShmFD = fd;
    sShmSize = totalSize;
    sShmHeader = (FTLoopbackSharedHeader*)mapped;
    sShmAudioData = (float*)((uint8_t*)mapped + sizeof(FTLoopbackSharedHeader));
}

static bool sLegacyReadStarted = false;
static const UInt32 kLegacyTargetLatency = 16384;
static const UInt32 kLegacyMaxLatency = 32768;
static bool sShmNeedsClose = false;  // Flag for deferred cleanup (H8: never call CloseSharedMemory on RT thread)

/// Read from shared memory ring buffer (legacy path).
static UInt32 ReadFromSharedMemory(float* outBuffer, UInt32 framesToRead, UInt32 channels) {
    if (sShmHeader == NULL || sShmAudioData == NULL) return 0;

    uint32_t isActive = __atomic_load_n(&sShmHeader->isActive, __ATOMIC_ACQUIRE);
    if (!isActive) {
        // H8: Don't call CloseSharedMemory() here — we're on the RT thread.
        // Set a flag for deferred cleanup in StopIO.
        sShmNeedsClose = true;
        sLegacyReadStarted = false;
        return 0;
    }

    uint32_t bufFrames = sShmHeader->bufferFrames;
    uint32_t shmChannels = sShmHeader->channels;
    if (bufFrames == 0 || shmChannels == 0) return 0;

    uint64_t writeHead = __atomic_load_n(&sShmHeader->writeHead, __ATOMIC_ACQUIRE);
    uint64_t readHead = __atomic_load_n(&sShmHeader->readHead, __ATOMIC_RELAXED);

    int64_t available = (int64_t)(writeHead - readHead);

    if (!sLegacyReadStarted) {
        if (available < (int64_t)kLegacyTargetLatency) return 0;
        sLegacyReadStarted = true;
        readHead = writeHead - kLegacyTargetLatency;
        __atomic_store_n(&sShmHeader->readHead, readHead, __ATOMIC_RELEASE);
        available = kLegacyTargetLatency;
    }

    if (available > (int64_t)kLegacyMaxLatency) {
        readHead = writeHead - kLegacyTargetLatency;
        __atomic_store_n(&sShmHeader->readHead, readHead, __ATOMIC_RELEASE);
        available = kLegacyTargetLatency;
    }

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
        for (UInt32 ch = minChannels; ch < channels; ch++) {
            outBuffer[outPos + ch] = 0.0f;
        }
    }

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
                                      Boolean* outWillDoInPlace);
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
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);

    CFUUIDRef iunknownUUID = CFUUIDGetConstantUUIDWithBytes(NULL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);

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

    // Zero the passthrough buffer on init
    memset(sPassthroughBuffer, 0, sizeof(sPassthroughBuffer));

    syslog(LOG_ERR, "FTLoopback: Initialize called! Bidirectional virtual audio cable loaded.");
    os_log_info(sLog, "FineTune Loopback driver initialized (bidirectional)");
    return kAudioHardwareNoError;
}

static OSStatus FT_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FT_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FT_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo* inClientInfo) {
    os_log_info(sLog, "AddDeviceClient: pid=%d", inClientInfo->mProcessID);
    return kAudioHardwareNoError;
}

static OSStatus FT_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo) {
    os_log_info(sLog, "RemoveDeviceClient: pid=%d", inClientInfo->mProcessID);
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
// MARK: - Helper: is this a stream object?
// ============================================================================

static inline bool IsStreamObject(AudioObjectID objectID) {
    return objectID == kFTObjectID_Stream_Input || objectID == kFTObjectID_Stream_Output;
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
        // case kAudioDevicePropertyIcon:  // L4: removed — we don't provide an icon
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioObjectPropertyControlList:
            return true;
        }
        break;

    // --- Streams (Input and Output share the same property set) ---
    case kFTObjectID_Stream_Input:
    case kFTObjectID_Stream_Output:
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

    case kFTObjectID_Stream_Input:
    case kFTObjectID_Stream_Output:
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
            // Scope-aware: input stream + output stream + volume = 3 max
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                *outDataSize = sizeof(AudioObjectID); // just input stream
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID); // just output stream
            } else {
                *outDataSize = 3 * sizeof(AudioObjectID); // both streams + volume
            }
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
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                *outDataSize = sizeof(AudioObjectID); // 1 input stream
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID); // 1 output stream
            } else {
                *outDataSize = 2 * sizeof(AudioObjectID); // both streams
            }
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
        // case kAudioDevicePropertyIcon:  // L4: removed\n        //     *outDataSize = sizeof(CFURLRef);\n        //     return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = sizeof(AudioObjectID); // 1 control (volume)
            return kAudioHardwareNoError;
        }
        break;

    // --- Streams (Input and Output) ---
    case kFTObjectID_Stream_Input:
    case kFTObjectID_Stream_Output:
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
            // M5: Device's base class is kAudioDeviceClassID, not kAudioObjectClassID
            *((AudioClassID*)outData) = kAudioDeviceClassID;
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
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                ids[count++] = kFTObjectID_Stream_Input;
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                ids[count++] = kFTObjectID_Stream_Output;
            } else {
                // Global scope: return all objects
                ids[count++] = kFTObjectID_Stream_Input;
                ids[count++] = kFTObjectID_Stream_Output;
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
            // Can be default for BOTH input AND output
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *((UInt32*)outData) = 0; // Not suitable as system alert device
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyStreams: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                ids[0] = kFTObjectID_Stream_Input;
                *outDataSize = sizeof(AudioObjectID);
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                ids[0] = kFTObjectID_Stream_Output;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                // Global: both streams
                ids[0] = kFTObjectID_Stream_Output;
                ids[1] = kFTObjectID_Stream_Input;
                *outDataSize = 2 * sizeof(AudioObjectID);
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

        // L4: Icon property removed — returning NULL causes Audio MIDI Setup
        // to show no icon. Remove from HasProperty if we don't provide one.
        // case kAudioDevicePropertyIcon:
        //     *((CFURLRef*)outData) = NULL;
        //     *outDataSize = sizeof(CFURLRef);
        //     return kAudioHardwareNoError;

        case kAudioObjectPropertyControlList:
            *((AudioObjectID*)outData) = kFTObjectID_Volume;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        break;

    // ==== Stream Properties (Input & Output share logic, differ only in direction) ====
    case kFTObjectID_Stream_Input:
    case kFTObjectID_Stream_Output:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            // M5: Stream's base class is kAudioStreamClassID, not kAudioObjectClassID
            *((AudioClassID*)outData) = kAudioStreamClassID;
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
            // Input stream: direction=1 (recording FROM device)
            // Output stream: direction=0 (playing TO device)
            *((UInt32*)outData) = (inObjectID == kFTObjectID_Stream_Input) ? 1 : 0;
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
            // H4: Reject sample rate change while IO is running
            if (gDevice_IOIsRunning > 0) return kAudioHardwareNotRunningError;
            Float64 newRate = *((const Float64*)inData);
            bool valid = false;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                if (kFTSupportedSampleRates[i] == newRate) { valid = true; break; }
            }
            if (!valid) return kAudioHardwareIllegalOperationError;
            sSampleRate = newRate;
            os_log_info(sLog, "Sample rate changed to %.0f", newRate);
            // H3: Notify clients of property change
            if (sHost != NULL) {
                AudioObjectPropertyAddress addr = { kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                sHost->PropertiesChanged(sHost, kFTObjectID_Device, 1, &addr);
            }
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyBufferFrameSize: {
            // H4: Reject buffer size change while IO is running
            if (gDevice_IOIsRunning > 0) return kAudioHardwareNotRunningError;
            UInt32 newSize = *((const UInt32*)inData);
            if (newSize < kFTMinBufferFrames || newSize > kFTMaxBufferFrames)
                return kAudioHardwareIllegalOperationError;
            sBufferFrameSize = newSize;
            os_log_info(sLog, "Buffer frame size changed to %u", newSize);
            // H3: Notify clients of property change
            if (sHost != NULL) {
                AudioObjectPropertyAddress addr = { kAudioDevicePropertyBufferFrameSize,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                sHost->PropertiesChanged(sHost, kFTObjectID_Device, 1, &addr);
            }
            return kAudioHardwareNoError;
        }
        }
        break;

    case kFTObjectID_Stream_Input:
    case kFTObjectID_Stream_Output:
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            const AudioStreamBasicDescription* desc = (const AudioStreamBasicDescription*)inData;
            // M6: Validate full stream format, not just sample rate
            if (desc->mFormatID != kAudioFormatLinearPCM ||
                desc->mBitsPerChannel != 32 ||
                desc->mChannelsPerFrame != kFTChannelCount ||
                !(desc->mFormatFlags & kAudioFormatFlagIsFloat)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            bool validRate = false;
            for (UInt32 i = 0; i < kFTNumSampleRates; i++) {
                if (kFTSupportedSampleRates[i] == desc->mSampleRate) { validRate = true; break; }
            }
            if (!validRate) return kAudioDeviceUnsupportedFormatError;
            // H4: Reject while IO is running
            if (gDevice_IOIsRunning > 0) return kAudioHardwareNotRunningError;
            sSampleRate = desc->mSampleRate;
            // H3: Notify clients of format change
            if (sHost != NULL) {
                AudioObjectPropertyAddress addr = { inAddress->mSelector,
                    inAddress->mScope, inAddress->mElement };
                sHost->PropertiesChanged(sHost, inObjectID, 1, &addr);
            }
            return kAudioHardwareNoError;
        }
        }
        break;

    case kFTObjectID_Volume:
        switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue: {
            Float32 val = *((const Float32*)inData);
            sVolumeLevel = (val < 0.0f) ? 0.0f : ((val > 1.0f) ? 1.0f : val);
            // H3: Notify clients of volume change
            if (sHost != NULL) {
                AudioObjectPropertyAddress addr = { kAudioLevelControlPropertyScalarValue,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                sHost->PropertiesChanged(sHost, kFTObjectID_Volume, 1, &addr);
            }
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyDecibelValue: {
            Float32 dB = *((const Float32*)inData);
            sVolumeLevel = (Float32)pow(10.0, (double)dB / 20.0);
            if (sVolumeLevel > 1.0f) sVolumeLevel = 1.0f;
            if (sVolumeLevel < 0.0f) sVolumeLevel = 0.0f;
            // H3: Notify clients of volume change
            if (sHost != NULL) {
                AudioObjectPropertyAddress addr = { kAudioLevelControlPropertyDecibelValue,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                sHost->PropertiesChanged(sHost, kFTObjectID_Volume, 1, &addr);
            }
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

    pthread_mutex_lock(&gDevice_IOMutex);

    if (gDevice_IOIsRunning == 0) {
        // First client — initialize timing anchor
        Float64 theHostClockFrequency = 0.0;
        mach_timebase_info_data_t tbInfo;
        mach_timebase_info(&tbInfo);
        theHostClockFrequency = (Float64)tbInfo.denom / (Float64)tbInfo.numer * 1000000000.0;
        gDevice_HostTicksPerFrame = theHostClockFrequency / sSampleRate;

        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        gDevice_PreviousTicks = 0.0;

        // Reset passthrough buffer for fresh IO session
        memset(sPassthroughBuffer, 0, sizeof(sPassthroughBuffer));
        sPassthroughFrameCount.store(0, std::memory_order_relaxed);
        sLegacyReadStarted = false;
        sShmNeedsClose = false;

        // C4: Open shared memory here (non-RT thread), not in DoIOOperation
        if (sShmHeader == NULL) {
            OpenSharedMemory();
        }
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

    // H6: Clean up shared memory when all IO clients have disconnected
    // H8: This is the deferred cleanup from the RT thread flag
    if (gDevice_IOIsRunning == 0) {
        if (sShmNeedsClose) {
            CloseSharedMemory();
            sShmRetryHostTime = 0;
            sShmNeedsClose = false;
        }
    }

    pthread_mutex_unlock(&gDevice_IOMutex);

    return kAudioHardwareNoError;
}

static OSStatus FT_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    // C2: Lock-free — this runs on the RT IO thread every cycle.
    // No mutex here. GetZeroTimeStamp is the sole RT-thread accessor;
    // StartIO resets the state before any IO begins (under mutex, no race).

    UInt64 theCurrentHostTime = mach_absolute_time();
    Float64 theHostTicksPerPeriod = gDevice_HostTicksPerFrame * (Float64)kFTZeroTimeStampPeriod;
    Float64 theNextTickOffset = gDevice_PreviousTicks + theHostTicksPerPeriod;
    UInt64 theNextHostTime = gDevice_AnchorHostTime + (UInt64)theNextTickOffset;

    if (theNextHostTime <= theCurrentHostTime) {
        ++gDevice_NumberTimeStamps;
        gDevice_PreviousTicks = theNextTickOffset;
    }

    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kFTZeroTimeStampPeriod);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)gDevice_PreviousTicks;
    *outSeed = 1;

    return kAudioHardwareNoError;
}

static OSStatus FT_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outWillDoInPlace) {
    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
        *outWillDo = true;
        *outWillDoInPlace = true;
        break;
    case kAudioServerPlugInIOOperationWriteMix:
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

    // === OUTPUT: App writing audio TO the device (rekordbox → buffer) ===
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // C1: Clamp to max buffer size to prevent overflow
        UInt32 clampedFrames = (inIOBufferFrameSize > kFTMaxBufferFrames)
                                ? kFTMaxBufferFrames : inIOBufferFrameSize;
        UInt32 bytesToCopy = clampedFrames * kFTChannelCount * sizeof(float);
        memcpy(sPassthroughBuffer, ioMainBuffer, bytesToCopy);
        // C3: Release semantics — ensures buffer data is visible before count
        sPassthroughFrameCount.store(clampedFrames, std::memory_order_release);
        return kAudioHardwareNoError;
    }

    // === INPUT: App reading audio FROM the device (buffer → Ableton) ===
    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        float* outBuffer = (float*)ioMainBuffer;
        UInt32 totalSamples = inIOBufferFrameSize * kFTChannelCount;

        // C3: Acquire semantics — ensures we see the buffer data written before count
        UInt32 availableFrames = sPassthroughFrameCount.load(std::memory_order_acquire);

        // Direct copy from passthrough buffer — zero overhead
        if (availableFrames > 0) {
            // C1: Also clamp read side for safety
            UInt32 framesToCopy = (inIOBufferFrameSize < availableFrames)
                                  ? inIOBufferFrameSize : availableFrames;
            if (framesToCopy > kFTMaxBufferFrames) framesToCopy = kFTMaxBufferFrames;
            UInt32 bytesToCopy = framesToCopy * kFTChannelCount * sizeof(float);
            memcpy(outBuffer, sPassthroughBuffer, bytesToCopy);

            // Zero remaining frames if buffer sizes differ
            if (framesToCopy < inIOBufferFrameSize) {
                UInt32 remainingSamples = (inIOBufferFrameSize - framesToCopy) * kFTChannelCount;
                memset(outBuffer + framesToCopy * kFTChannelCount, 0, remainingSamples * sizeof(float));
            }

            // M3: Volume is intentionally applied only in ReadInput, not WriteMix.
            // This preserves the raw audio in the passthrough buffer (lossless),
            // and applies volume control at the consumer side.
            // Apply volume
            if (sVolumeLevel < 0.999f) {
                for (UInt32 i = 0; i < framesToCopy * kFTChannelCount; i++) {
                    outBuffer[i] *= sVolumeLevel;
                }
            }
        } else {
            // No data from passthrough — try shared memory (legacy fallback)
            memset(outBuffer, 0, totalSamples * sizeof(float));
            // C4: Don't call OpenSharedMemory() here — it was opened in StartIO
            if (sShmHeader != NULL) {
                UInt32 framesRead = ReadFromSharedMemory(outBuffer, inIOBufferFrameSize, kFTChannelCount);
                if (framesRead > 0 && sVolumeLevel < 0.999f) {
                    for (UInt32 i = 0; i < framesRead * kFTChannelCount; i++) {
                        outBuffer[i] *= sVolumeLevel;
                    }
                }
            }
        }

        return kAudioHardwareNoError;
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
    // L6: Cache the UUID to avoid repeated Create/Release
    static CFUUIDRef pluginTypeUUID = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    if (!CFEqual(requestedTypeUUID, pluginTypeUUID)) {
        return NULL;
    }

    os_log_info(sLog, "Factory called, returning bidirectional driver interface");
    FT_AddRef(NULL);
    return &sDriverInterfacePtr;
}

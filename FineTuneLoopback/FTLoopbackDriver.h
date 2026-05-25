// FineTuneLoopback/FTLoopbackDriver.h
//
// CoreAudio AudioServerPlugIn driver for the FineTune Loopback virtual audio device.
// This creates a virtual input device that reads audio from POSIX shared memory
// written by the FineTune app's audio callback.

#ifndef FTLOOPBACK_DRIVER_H
#define FTLOOPBACK_DRIVER_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// Plugin UUID (factory): 5A8B4F1E-3C9D-4E2A-B7F6-8D1E0A2C4B6E
#define kFTLoopbackPluginFactoryUUID \
    CFUUIDGetConstantUUIDWithBytes(NULL, \
        0x5A, 0x8B, 0x4F, 0x1E, 0x3C, 0x9D, 0x4E, 0x2A, \
        0xB7, 0xF6, 0x8D, 0x1E, 0x0A, 0x2C, 0x4B, 0x6E)

// Object IDs — fixed static layout
enum {
    kFTObjectID_PlugIn      = kAudioObjectPlugInObject,  // 1 (required by HAL)
    kFTObjectID_Device      = 2,
    kFTObjectID_Stream      = 3,
    // Volume control on the virtual device (optional, useful for DAW level)
    kFTObjectID_Volume      = 4,
};

// Device constants
#define kFTLoopbackDeviceUID        "com.finetuneapp.loopback"
#define kFTLoopbackDeviceModelUID   "FTLoopbackModel"
#define kFTLoopbackDeviceName       "FineTune Loopback"
#define kFTLoopbackManufacturer     "FineTune"

// Supported sample rates
static const Float64 kFTSupportedSampleRates[] = { 44100.0, 48000.0, 96000.0 };
#define kFTNumSampleRates (sizeof(kFTSupportedSampleRates) / sizeof(Float64))

// Default configuration
#define kFTDefaultSampleRate        44100.0
#define kFTDefaultBufferFrames      512
#define kFTMinBufferFrames          64
#define kFTMaxBufferFrames          4096
#define kFTChannelCount             2

// Custom clock domain (non-zero, non-default)
#define kFTClockDomain              0xF17E7001

#endif // FTLOOPBACK_DRIVER_H

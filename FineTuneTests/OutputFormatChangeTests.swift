import AudioToolbox
import Testing
@testable import FineTune

/// Coverage for the pure decision behind recreating a tap's aggregate on an output format change.
/// `isMeaningfulRateChange` decides when the sample-rate listener fires; `OutputFormatFingerprint`
/// covers bit-depth changes the nominal-rate listener misses.
@Suite("Output format change detection")
struct OutputFormatChangeTests {

    @Test("Fires on any change to a different valid rate")
    func firesOnChange() {
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 24_000)) // join call
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 48_000)) // leave call
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 44_100, newRate: 48_000)) // within A2DP
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 16_000)) // within call mode
        #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 0, newRate: 48_000))      // first valid read
    }

    @Test("Does not fire when the rate is unchanged")
    func noFireOnSameRate() {
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 48_000))
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 24_000))
    }

    /// Regression: a transient/failed read arrives as `newRate <= 0`. It must never fire, and
    /// the caller must not store it as the baseline — otherwise the next real read looks like
    /// "no change" (oldRate == newRate after a clobber) and the A2DP↔SCO retune is missed,
    /// re-introducing the crackle.
    @Test("Transient failed read (rate 0) never fires")
    func transientZeroNeverFails() {
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 0, newRate: 0))
    }

    @Test("Transport-specific debounce constants")
    func debounceConstants() {
        #expect(AudioDeviceMonitor.bluetoothSampleRateDebounceMs == 150)
        #expect(AudioDeviceMonitor.wiredSampleRateDebounceMs == 50)
    }

    @Test("OutputFormatFingerprint detects sample rate change")
    func fingerprintRateChange() {
        let old = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        let new = OutputFormatFingerprint(sampleRate: 44_100, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        #expect(OutputFormatFingerprint.isMeaningfulChange(old: old, new: new))
    }

    @Test("OutputFormatFingerprint detects bit depth change at same rate")
    func fingerprintBitDepthChange() {
        let old = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        let new = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 32)
        #expect(OutputFormatFingerprint.isMeaningfulChange(old: old, new: new))
    }

    @Test("OutputFormatFingerprint ignores unchanged fingerprint")
    func fingerprintNoChange() {
        let old = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        let new = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        #expect(!OutputFormatFingerprint.isMeaningfulChange(old: old, new: new))
    }

    @Test("OutputFormatFingerprint rejects transient invalid new fingerprint")
    func fingerprintTransientInvalid() {
        let old = OutputFormatFingerprint(sampleRate: 48_000, formatID: kAudioFormatLinearPCM, bitsPerChannel: 24)
        let invalid = OutputFormatFingerprint(sampleRate: 0, formatID: 0, bitsPerChannel: 0)
        #expect(!OutputFormatFingerprint.isMeaningfulChange(old: old, new: invalid))
    }
}

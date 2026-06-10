import Testing
@testable import FineTune

/// Coverage for the pure decision behind recreating a tap's aggregate on a Bluetooth output's
/// nominal-rate change (A2DP ↔ SCO/HFP). This helper decides when the rate-change listener fires.
@Suite("BT rate-change detection")
struct BTCallModeTransitionTests {

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

    /// Regression (M2): a transient/failed read arrives as `newRate <= 0`. It must never fire, and
    /// the caller must not store it as the baseline — otherwise the next real read looks like
    /// "no change" (oldRate == newRate after a clobber) and the A2DP↔SCO retune is missed,
    /// re-introducing the crackle.
    @Test("Transient/failed read (rate 0) never fires")
    func transientZeroNeverFires() {
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 0, newRate: 0))
    }
}

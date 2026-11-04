import Testing
@testable import FineTune

@Suite("Bluetooth paired device discovery")
struct BluetoothDeviceDiscoveryTests {

    @Test("Audio hardware is recognized from its cached device class")
    func recognizesAudioHardware() {
        #expect(BluetoothDeviceMonitor.isAudioDeviceClass(major: 4))
    }

    @Test("Non-audio paired peripherals remain excluded", arguments: [UInt32(0), 1, 5])
    func rejectsNonAudioHardware(deviceClassMajor: UInt32) {
        #expect(!BluetoothDeviceMonitor.isAudioDeviceClass(major: deviceClassMajor))
    }
}

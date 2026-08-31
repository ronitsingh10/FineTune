// FineTuneTests/StereoBalanceTests.swift
import Foundation
import Testing
@testable import FineTune

@Suite("StereoBalance")
struct StereoBalanceTests {

    @Test("clamp keeps finite values in 0...1 and maps non-finite to center")
    func clamp() {
        #expect(StereoBalance.clamp(0) == 0)
        #expect(StereoBalance.clamp(1) == 1)
        #expect(StereoBalance.clamp(0.5) == 0.5)
        #expect(StereoBalance.clamp(-0.2) == 0)
        #expect(StereoBalance.clamp(1.5) == 1)
        #expect(StereoBalance.clamp(.nan) == StereoBalance.center)
        #expect(StereoBalance.clamp(.infinity) == StereoBalance.center)
    }

    @Test("channelGains attenuates quieter side only")
    func channelGains() {
        let center = StereoBalance.channelGains(for: 0.5)
        #expect(abs(center.left - 1) < 1e-5)
        #expect(abs(center.right - 1) < 1e-5)

        let fullLeft = StereoBalance.channelGains(for: 0)
        #expect(abs(fullLeft.left - 1) < 1e-5)
        #expect(abs(fullLeft.right - 0) < 1e-5)

        let fullRight = StereoBalance.channelGains(for: 1)
        #expect(abs(fullRight.left - 0) < 1e-5)
        #expect(abs(fullRight.right - 1) < 1e-5)

        let quarterLeft = StereoBalance.channelGains(for: 0.25)
        #expect(abs(quarterLeft.left - 1) < 1e-5)
        #expect(abs(quarterLeft.right - 0.5) < 1e-5)

        let threeQuarter = StereoBalance.channelGains(for: 0.75)
        #expect(abs(threeQuarter.left - 0.5) < 1e-5)
        #expect(abs(threeQuarter.right - 1) < 1e-5)
    }

    @Test("fromChannelVolumes is inverse of channelGains for equal-max volumes")
    func fromChannelVolumesRoundTrip() {
        let samples: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        for balance in samples {
            let gains = StereoBalance.channelGains(for: balance)
            let recovered = StereoBalance.fromChannelVolumes(left: gains.left, right: gains.right)
            #expect(abs(recovered - balance) < 1e-4)
        }
    }

    @Test("fromChannelVolumes returns center for equal or silent channels")
    func fromChannelVolumesEdgeCases() {
        #expect(StereoBalance.fromChannelVolumes(left: 0.8, right: 0.8) == StereoBalance.center)
        #expect(StereoBalance.fromChannelVolumes(left: 0, right: 0) == StereoBalance.center)
    }
}

@Suite("SettingsManager — deviceBalances")
@MainActor
struct DeviceBalanceSettingsTests {

    @Test("deviceBalances round-trip through encode/decode with clamping")
    func roundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.deviceBalances = [
            "uid-speakers": 0.25,
            "uid-headphones": 1.5, // will be clamped on decode path via setter/decode
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.deviceBalances["uid-speakers"] == 0.25)
        // Raw encode keeps 1.5; decode clamps
        #expect(decoded.deviceBalances["uid-headphones"] == 1.0)
        #expect(decoded.version == 13)
    }

    @Test("SettingsManager get/setDeviceBalance persists clamped values")
    func managerGetSet() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manager = SettingsManager(directory: tempDir)
        #expect(manager.getDeviceBalance(for: "uid-a") == nil)

        manager.setDeviceBalance(for: "uid-a", to: -0.5)
        #expect(manager.getDeviceBalance(for: "uid-a") == 0)

        manager.setDeviceBalance(for: "uid-a", to: 0.3)
        #expect(manager.getDeviceBalance(for: "uid-a") == 0.3)

        manager.resetAllSettings()
        #expect(manager.getDeviceBalance(for: "uid-a") == nil)
    }

    @Test("Missing deviceBalances key defaults to empty on older settings files")
    func missingKeyDefaultsEmpty() throws {
        let json = #"""
        {
          "version": 12,
          "appVolumes": {},
          "appSettings": {
            "defaultNewAppVolume": 1.0,
            "launchAtLogin": false,
            "menuBarIconStyle": "Default",
            "lockInputDevice": true,
            "showDeviceDisconnectAlerts": true,
            "loudnessCompensationEnabled": false,
            "loudnessEqualizationEnabled": false,
            "mediaKeyControlEnabled": true,
            "hudStyle": "tahoe"
          }
        }
        """#
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(decoded.deviceBalances.isEmpty)
        #expect(decoded.version == 12)
    }
}

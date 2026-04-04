- Added private `IOBluetoothDevice` Objective-C category declarations in a bridging header and wired `SWIFT_OBJC_BRIDGING_HEADER` for both app target Debug/Release configs.
- Implemented AirPods listening-mode wrappers with per-access `responds(to:)` guards and KVC reads/writes, using `setValue(Int(mode), forKey: "listeningMode")` for setting.
- Kept adaptive support detection as a runtime probe using device name matching (`"AirPods Pro"`) to exclude unsupported models like AirPods Max.
- MAC↔UID correlation uses name-based matching between IOBluetooth connected devices and CoreAudio output devices — both surfaces expose the same device name for BT audio devices.
- `runOnBTQueue` closure returning `Optional<CustomType>` requires explicit return type annotation `() -> AirPodsState? in` — Swift can't infer `T` as optional from variable binding alone.
- `notifyDeviceAppearedInCoreAudio` extended with optional parameters (default nil) to remain backward-compatible while accepting CoreAudio device info for correlation.
- AudioEngine's `onDeviceConnected` callback already provides `(deviceUID, deviceName)` — perfect injection point for correlation data.
- `handleDeviceDisconnected(deviceUID:)` added as a separate method called from AudioEngine's `onDeviceDisconnected` — keeps cleanup explicit rather than buried in `refresh()`.

## Task 4: Show disconnected BT devices in normal mode
- Normal mode paired section added after `ForEach(sortedDevices)` in `devicesContent` (line ~575)
- `PairedDeviceRow.isDisconnected` param (default true) controls dimmed styling: icon 0.6 opacity, secondary text
- Edit mode section (line ~472) unchanged — additive change only
- Bluetooth-off message shown in both normal and edit mode now
- `isDisconnected` has default value so all existing call sites (edit mode, previews) work unchanged

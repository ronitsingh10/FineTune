# AirPods Integration Improvements

## TL;DR

> **Quick Summary**: Add first-class AirPods support to FineTune by showing disconnected Bluetooth devices in the main device list (click to connect + auto-select), adding a listening mode dropdown (ANC/Transparency/Adaptive/Off) using IOBluetooth private APIs, and displaying battery level for connected AirPods.
> 
> **Deliverables**:
> - Dev environment setup and verified build
> - Disconnected Bluetooth devices visible in main output list with connect-on-click
> - Listening mode dropdown on connected AirPods device rows
> - Battery percentage display for connected AirPods
> - Objective-C bridging header for IOBluetooth private API declarations
> 
> **Estimated Effort**: Medium
> **Parallel Execution**: YES - 3 waves
> **Critical Path**: Task 1 → Task 2 → Task 3 → Task 5 → Task 7 → Task 8 → F1-F4

---

## Context

### Original Request
User forked FineTune (macOS menu bar audio control app) and wants better AirPods integration:
1. Show disconnected Bluetooth devices in the main device list (not hidden behind edit mode), with click-to-connect + auto-select as output
2. Add noise cancellation / listening mode control (ANC, Transparency, Adaptive, Off) as a dropdown
3. Battery level display for connected AirPods
4. First-time dev setup — user has Xcode but never opened the project

### Interview Summary
**Key Discussions**:
- **Private API risk**: User accepts that ANC control requires undocumented IOBluetooth APIs that could break in future macOS updates. This is a community tool, not App Store distributed.
- **AirPods Pro 3 modes**: User confirmed AirPods Pro 3 only have ANC/Transparency/Adaptive (NO "Off" option). Modes vary per model, so the dropdown MUST be dynamic based on runtime capability queries.
- **Connect behavior**: Click on disconnected device should connect AND auto-select as output device (not just connect).
- **ANC persistence**: NOT needed — macOS handles this natively.
- **Battery**: Single combined percentage, not left/right/case breakdown.
- **Tests**: No unit tests — "just make it work". Build verification and runtime QA only.

**Research Findings**:
- `IOBluetoothDevice.listeningMode` (unsigned char): 1=Off, 2=ANC, 3=Transparency, 4=Adaptive
- `isANCSupported` / `isTransparencySupported` — Boolean properties for capability detection
- Adaptive mode value (4) confirmed by LibrePods reverse engineering but needs runtime verification
- NoiseBuddy's AVFoundation approach is BROKEN on recent macOS — IOBluetooth private API is the viable path
- Battery via IOKit `AppleDeviceManagementHIDEventService` → `BatteryPercent` property (public API)
- Existing `DropdownMenu.swift` component can be reused for listening mode picker
- AirPods icon detection by name already exists in codebase

### Metis Review
**Identified Gaps** (addressed):
- **AudioDevice ↔ IOBluetoothDevice correlation**: CoreAudio uses `uid`, IOBluetooth uses MAC address. Plan includes explicit correlation strategy via device name matching during connection + storing MAC↔UID mapping.
- **Two model types in one list**: Plan uses heterogeneous list approach — `PairedDeviceRow` below `DeviceRow` in main list (no model merge).
- **setValue vs perform for listeningMode**: Must use `setValue(_:forKey:)` not `perform(_:with:)` — UInt8 gets corrupted by NSObject boxing. Explicitly noted in guardrails.
- **Dynamic mode availability**: AirPods Pro 3 has no "Off", AirPods Max has no "Adaptive". Plan queries capabilities at runtime, not hardcoded per model.

---

## Work Objectives

### Core Objective
Bring AirPods from a hidden-behind-edit-mode afterthought to a first-class citizen in FineTune's device list, with one-click connection, listening mode control, and battery display.

### Concrete Deliverables
- `FineTune-Bridging-Header.h` — Objective-C bridging header declaring IOBluetooth private interface
- Modified `BluetoothDeviceMonitor.swift` — Extended with listening mode read/write, battery polling, and device correlation
- Modified `PairedBluetoothDevice.swift` — Optional AirPods-specific properties
- Modified `MenuBarPopupView.swift` — Disconnected devices in main list (not just edit mode)
- New `ListeningModePicker.swift` — Dropdown for ANC/Transparency/Adaptive/Off
- Modified `DeviceRow.swift` — Battery display + listening mode picker for AirPods
- Modified `AudioEngine.swift` — Connect-and-select flow for disconnected devices

### Definition of Done
- [ ] `Cmd+B` builds with zero errors and zero warnings from new code
- [ ] Disconnected paired Bluetooth devices appear below connected devices in main output list
- [ ] Clicking a disconnected device connects it and sets it as default output
- [ ] Connected AirPods Pro/Max show a listening mode dropdown
- [ ] Selecting a mode in the dropdown changes the actual listening mode on the AirPods
- [ ] Connected AirPods show battery percentage
- [ ] AirPods Pro 3 dropdown shows ANC/Transparency/Adaptive (no Off)
- [ ] AirPods Max dropdown shows Off/ANC/Transparency (no Adaptive)
- [ ] Non-AirPods Bluetooth devices show no listening mode controls
- [ ] All private API calls guarded with `responds(to:)` — graceful degradation if API unavailable

### Must Have
- Dynamic mode list per device (not hardcoded per model name)
- All private API calls guarded by `responds(to: Selector)` checks
- All IOBluetooth calls on existing `btQueue` serial queue
- `setValue(_:forKey: "listeningMode")` for setting mode (NOT `perform(_:with:)`)
- Disconnected devices visually distinct from connected (dimmed/different style)
- Graceful degradation: if private APIs don't respond, silently hide ANC controls

### Must NOT Have (Guardrails)
- **DO NOT** refactor or split `MenuBarPopupView.swift` — surgical changes only (it's 1110 lines, resist the urge)
- **DO NOT** create a unified device model merging AudioDevice + PairedBluetoothDevice
- **DO NOT** add listening mode persistence to SettingsManager (macOS handles this)
- **DO NOT** change PairedBluetoothDevice from struct to class
- **DO NOT** use `perform(_:with:)` for setting listeningMode (corrupts UInt8 values)
- **DO NOT** add left/right/case battery breakdown (single % only)
- **DO NOT** add Conversation Awareness, Personalized Volume, or Spatial Audio controls
- **DO NOT** add battery low notifications
- **DO NOT** add auto-reconnect on app launch
- **DO NOT** build polling infrastructure/framework — use simple `Timer.scheduledTimer`
- **DO NOT** show battery for non-AirPods devices
- **DO NOT** create new dispatch queues — use existing `btQueue`
- **DO NOT** add connection retry logic beyond existing 12s timeout

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES (XCTest, 12 existing tests)
- **Automated tests**: NO — user explicitly requested "just make it work"
- **Framework**: N/A
- **Verification method**: Build verification (`xcodebuild`) + agent-executed runtime QA

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Build verification**: `xcodebuild build` must succeed with zero errors
- **Runtime verification**: Run app, interact with popup, verify behavior via Xcode console logs
- **Private API verification**: Console log output confirming API responds/doesn't respond

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — foundation):
├── Task 1: Dev setup + build verification [quick]
├── Task 2: Bridging header + private API extensions + runtime discovery [deep]
└── Task 3: Extend BluetoothDeviceMonitor with AirPods capabilities [unspecified-high]
    (Task 3 depends on Task 2)
    (Task 1 is independent)

Wave 2 (After Wave 1 — features, MAX PARALLEL):
├── Task 4: Show disconnected devices in main list [unspecified-high]
├── Task 5: Create ListeningModePicker component [visual-engineering]
├── Task 6: Add battery level reading via IOKit [unspecified-high]
    (Task 4 depends on Task 3 for model changes)
    (Task 5 depends on Task 2 for ListeningMode enum)
    (Task 6 depends on Task 3 for BluetoothDeviceMonitor extensions)

Wave 3 (After Wave 2 — integration):
├── Task 7: Integrate listening mode + battery into DeviceRow [visual-engineering]
├── Task 8: Connect-and-select flow for disconnected devices [deep]
    (Task 7 depends on Tasks 5 + 6)
    (Task 8 depends on Task 4)

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: Task 1 → Task 2 → Task 3 → Task 5 → Task 7 → Task 8 → F1-F4
Parallel Speedup: ~50% faster than sequential
Max Concurrent: 3 (Wave 2)
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| 1 | — | 2, 3, 4, 5, 6, 7, 8 | 1 |
| 2 | 1 | 3, 5, 7 | 1 |
| 3 | 2 | 4, 6, 7, 8 | 1 |
| 4 | 3 | 8 | 2 |
| 5 | 2 | 7 | 2 |
| 6 | 3 | 7 | 2 |
| 7 | 5, 6 | F1-F4 | 3 |
| 8 | 4 | F1-F4 | 3 |
| F1-F4 | 7, 8 | — | FINAL |

### Agent Dispatch Summary

- **Wave 1**: **3 tasks** — T1 → `quick`, T2 → `deep`, T3 → `unspecified-high`
- **Wave 2**: **3 tasks** — T4 → `unspecified-high`, T5 → `visual-engineering`, T6 → `unspecified-high`
- **Wave 3**: **2 tasks** — T7 → `visual-engineering`, T8 → `deep`
- **FINAL**: **4 tasks** — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. Dev Setup + Build Verification

  **What to do**:
  - Open `FineTune.xcodeproj` in Xcode
  - Verify the project builds successfully with `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS'`
  - Identify and document the Xcode build settings: deployment target, Swift version, signing team
  - If signing fails (likely — forked repo won't have original team ID), configure "Sign to Run Locally" or set signing team to personal
  - Verify the app launches and the menu bar icon appears
  - Document any build warnings or issues

  **Must NOT do**:
  - Do not change any source code
  - Do not upgrade dependencies or Swift version
  - Do not modify build settings beyond signing configuration

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single-step verification task, no code changes needed
  - **Skills**: [`backend-standards-task-completion`]
    - `backend-standards-task-completion`: Build verification patterns

  **Parallelization**:
  - **Can Run In Parallel**: NO (must complete first — all other tasks need a building project)
  - **Parallel Group**: Wave 1 (solo)
  - **Blocks**: Tasks 2, 3, 4, 5, 6, 7, 8
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `FineTune.xcodeproj/project.pbxproj` — Build configuration, signing settings, framework dependencies
  - `FineTune/FineTune.entitlements` — Required entitlements (audio capture, Bluetooth, microphone)
  - `FineTune/Info.plist` — App metadata, privacy descriptions, URL schemes

  **WHY Each Reference Matters**:
  - `project.pbxproj`: Need to check deployment target (macOS 15.0+), Swift version, and linked frameworks (IOBluetooth is weak-linked)
  - `FineTune.entitlements`: Bluetooth entitlement already present — verify `com.apple.security.device.bluetooth` is set
  - `Info.plist`: `NSBluetoothAlwaysUsageDescription` already present — verify no missing permission descriptions

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Project builds successfully
    Tool: Bash
    Preconditions: Xcode installed, project directory exists
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Check output contains "BUILD SUCCEEDED"
    Expected Result: Build succeeds with zero errors
    Failure Indicators: "BUILD FAILED", any "error:" lines in output
    Evidence: .sisyphus/evidence/task-1-build-success.txt

  Scenario: Build fails due to signing
    Tool: Bash
    Preconditions: No Apple Developer team configured
    Steps:
      1. If initial build fails with signing error, run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
      2. If that works, update project to use "Sign to Run Locally" or disable signing
      3. Re-run build to confirm
    Expected Result: Build succeeds after signing fix
    Failure Indicators: Non-signing errors in build output
    Evidence: .sisyphus/evidence/task-1-signing-fix.txt
  ```

  **Commit**: NO (no code changes)

- [x] 2. IOBluetooth Private API Bridging Header + Extensions

  **What to do**:
  - Create `FineTune/Support/FineTune-Bridging-Header.h` (or appropriate path) declaring private IOBluetooth interface:
    ```objc
    @interface IOBluetoothDevice (FineTunePrivate)
    @property (nonatomic, readonly) BOOL isANCSupported;
    @property (nonatomic, readonly) BOOL isTransparencySupported;
    @property (nonatomic) unsigned char listeningMode;
    @end
    ```
  - Configure the Xcode project to use this bridging header (Build Settings → Objective-C Bridging Header)
  - Create `FineTune/Audio/Extensions/IOBluetoothDevice+ListeningMode.swift` with safe Swift wrappers:
    - `var safeListeningMode: UInt8?` — reads `listeningMode` only if `responds(to:)` passes
    - `func setSafeListeningMode(_ mode: UInt8) -> Bool` — sets via `setValue(_:forKey: "listeningMode")`, returns success
    - `var isANCCapable: Bool` — safe wrapper for `isANCSupported`
    - `var isTransparencyCapable: Bool` — safe wrapper for `isTransparencySupported`
    - `var supportsAdaptive: Bool` — runtime probe: try reading current mode, check if device name contains "AirPods Pro" (AirPods Max does NOT support Adaptive)
  - Create `FineTune/Audio/Types/ListeningMode.swift` enum:
    ```swift
    enum ListeningMode: UInt8, CaseIterable, Identifiable {
        case off = 1
        case noiseCancellation = 2
        case transparency = 3
        case adaptive = 4
        
        var id: UInt8 { rawValue }
        var displayName: String { ... }
        var iconName: String { ... }  // SF Symbol
    }
    ```
  - Add runtime discovery logging: when app starts, log which private APIs respond and current mode for connected AirPods
  - **CRITICAL**: Use `setValue(Int(mode.rawValue), forKey: "listeningMode")` for setting — NOT `perform(_:with:)`
  - **CRITICAL**: ALL access must be guarded with `responds(to: Selector("listeningMode"))` or equivalent

  **Must NOT do**:
  - Do not use `perform(_:with:)` for setting listeningMode (corrupts UInt8 via NSObject boxing)
  - Do not use inline selector strings in Swift — use the bridging header approach
  - Do not add any UI code in this task

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Private API integration requires careful Objective-C bridging, runtime safety, and nuanced understanding of Swift-ObjC interop. Getting `setValue(_:forKey:)` vs `perform(_:with:)` wrong silently corrupts data.
  - **Skills**: [`backend-standards-refactor-code`]
    - `backend-standards-refactor-code`: Safe extension patterns, API wrapper design

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 1 build verification)
  - **Parallel Group**: Wave 1 (sequential after Task 1)
  - **Blocks**: Tasks 3, 5, 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:1-4` — Only file importing IOBluetooth; import pattern and serial queue isolation
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:197-207` — `runOnBTQueue` helper for safe IOBluetooth dispatch
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:248-256` — `suggestedIconName` showing name-based AirPods detection pattern
  - `FineTune/Audio/Types/TransportType.swift` — Existing enum pattern for audio types (follow same style)
  - `FineTune/Audio/Extensions/AudioDeviceID+Classification.swift:102-105` — AirPods name detection pattern (Pro/Max/Gen3)

  **External References**:
  - NoiseBuddy `IOBluetooth-Private.h`: https://github.com/insidegui/NoiseBuddy/blob/main/NoiseCore/Source/Support/IOBluetooth-Private.h — Reference for private API declarations
  - BTT AirPods gist: https://gist.github.com/BourgonLaurent/752d60484072d0e0649ea723d69205c6 — Shows listeningMode values (1=Off, 2=ANC, 3=Transparency)
  - LibrePods (confirmed value 4 = Adaptive)

  **WHY Each Reference Matters**:
  - `BluetoothDeviceMonitor.swift:197-207`: The `runOnBTQueue` pattern is how ALL IOBluetooth calls must be dispatched. New extensions must use this same pattern.
  - `TransportType.swift`: Follow the same enum design pattern (Sendable, Hashable, displayName computed property)
  - `AudioDeviceID+Classification.swift:102-105`: Name detection for AirPods variants — same logic needed for `supportsAdaptive` (AirPods Pro only, not Max)
  - NoiseBuddy header: The authoritative source for which properties exist on IOBluetoothDevice

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Bridging header compiles and private API responds
    Tool: Bash
    Preconditions: Task 1 build verification passed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify output contains "BUILD SUCCEEDED"
      3. Search new files for `responds(to:)` guards: `grep -r "responds" FineTune/Audio/Extensions/IOBluetoothDevice+ListeningMode.swift`
      4. Verify every public method in the extension uses responds(to:) guard
    Expected Result: Build succeeds; every public method in extension has responds(to:) guard
    Failure Indicators: Build failure; any public method without responds(to:) guard
    Evidence: .sisyphus/evidence/task-2-build-and-guards.txt

  Scenario: setValue used instead of perform for listeningMode
    Tool: Bash
    Preconditions: Extension file created
    Steps:
      1. Run `grep -n "perform(" FineTune/Audio/Extensions/IOBluetoothDevice+ListeningMode.swift` — should return NO matches
      2. Run `grep -n "setValue" FineTune/Audio/Extensions/IOBluetoothDevice+ListeningMode.swift` — should return matches for listeningMode setter
    Expected Result: Zero `perform(_:with:)` calls; at least one `setValue(_:forKey:)` call
    Failure Indicators: Any `perform(` match in the file
    Evidence: .sisyphus/evidence/task-2-no-perform.txt
  ```

  **Commit**: YES
  - Message: `feat: add IOBluetooth private API bridging header and safe Swift extensions`
  - Files: `FineTune-Bridging-Header.h`, `IOBluetoothDevice+ListeningMode.swift`, `ListeningMode.swift`, Xcode project config
  - Pre-commit: `xcodebuild build`

- [x] 3. Extend BluetoothDeviceMonitor with AirPods Capabilities

  **What to do**:
  - Add a MAC → device UID correlation map to `BluetoothDeviceMonitor`:
    - When `notifyDeviceAppearedInCoreAudio()` is called, match the newly connected CoreAudio device to the IOBluetooth device by **name** (both APIs expose `name`)
    - Store mapping: `private var macToUID: [String: String]` — populated on connection success
    - This map is critical: `DeviceRow` knows `AudioDevice.uid`, but listening mode needs `IOBluetoothDevice` (identified by MAC). The map bridges them.
  - Add connected AirPods state tracking:
    - `private(set) var connectedAirPodsState: [String: AirPodsState]` keyed by device UID
    - `AirPodsState` struct: `listeningMode: ListeningMode?`, `availableModes: [ListeningMode]`, `batteryPercent: Int?`, `macAddress: String`
  - Add method `func setListeningMode(_ mode: ListeningMode, forDeviceUID uid: String)`:
    - Look up MAC from `macToUID` (reverse lookup from uid)
    - Get `IOBluetoothDevice` by MAC on `btQueue`
    - Call safe setter from Task 2's extension
  - Add method `func refreshAirPodsState(for deviceUID: String)`:
    - Read current listening mode, available modes, battery from IOBluetooth device on `btQueue`
    - Determine available modes dynamically:
      1. Check `isANCCapable` → include `.noiseCancellation`
      2. Check `isTransparencyCapable` → include `.transparency`
      3. Check `supportsAdaptive` → include `.adaptive`
      4. If device supports ANC but current mode can be 1 (Off) → include `.off` (AirPods Pro 3 may NOT include this)
      5. Read current `listeningMode` value — if it's never 1 and device is AirPods Pro 3, exclude `.off`
    - **Mode discovery strategy**: Read current mode + try the known mode values. If a set fails (mode doesn't stick), that mode isn't available. More reliable than name-based guessing.
  - Add periodic state refresh via `Timer.scheduledTimer` (every 30 seconds, only while popup is visible)
  - Extend `PairedBluetoothDevice` struct with optional properties: `isAirPods: Bool` (name-based detection)

  **Must NOT do**:
  - Do not change PairedBluetoothDevice from struct to class
  - Do not create new dispatch queues — use existing `btQueue` via `runOnBTQueue`
  - Do not add listening mode persistence to SettingsManager
  - Do not poll when popup is hidden

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Complex state management with IOBluetooth threading, actor isolation, and device correlation logic
  - **Skills**: [`backend-standards-refactor-code`]
    - `backend-standards-refactor-code`: Safe state management patterns, extension of existing class

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 2 for bridging header and ListeningMode enum)
  - **Parallel Group**: Wave 1 (sequential after Task 2)
  - **Blocks**: Tasks 4, 6, 7, 8
  - **Blocked By**: Task 2

  **References**:

  **Pattern References**:
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift` (entire file) — The class being extended. Key patterns: `@Observable @MainActor`, serial queue dispatch, `RawPairedDevice` Sendable snapshot, connection state tracking
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:160-191` — `notifyDeviceAppearedInCoreAudio()` — hook point for MAC→UID correlation. When a device appears in CoreAudio after connect, match by name.
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:218-244` — `fetchPairedAudioDevices` — pattern for iterating IOBluetoothDevice.pairedDevices() on btQueue
  - `FineTune/Models/PairedBluetoothDevice.swift` — Struct to extend (add `isAirPods: Bool`)
  - `FineTune/Audio/Monitors/AudioDeviceMonitor.swift:20-23` — `onDeviceConnected` / `onDeviceDisconnected` callback pattern

  **API/Type References**:
  - `FineTune/Audio/Types/ListeningMode.swift` (from Task 2) — The enum for mode values
  - `FineTune/Audio/Extensions/IOBluetoothDevice+ListeningMode.swift` (from Task 2) — Safe wrappers to call

  **WHY Each Reference Matters**:
  - `BluetoothDeviceMonitor.swift:160-191`: This is WHERE to add MAC→UID correlation — when a new CoreAudio device appears, compare its name with the IOBluetooth device that was being connected
  - `BluetoothDeviceMonitor.swift:218-244`: Shows the exact pattern for safely iterating paired devices on btQueue with Sendable snapshots — follow this for AirPods state reads
  - `PairedBluetoothDevice.swift`: Must remain a struct. Add `isAirPods` computed from name.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Build succeeds with extended monitor
    Tool: Bash
    Preconditions: Tasks 1-2 completed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -n "runOnBTQueue" FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift | wc -l` — should be MORE than original count (was ~4)
    Expected Result: Build succeeds; new IOBluetooth calls all use runOnBTQueue
    Failure Indicators: Build failure; new IOBluetooth calls outside btQueue
    Evidence: .sisyphus/evidence/task-3-build-and-queue.txt

  Scenario: AirPodsState struct and correlation map exist
    Tool: Bash
    Preconditions: Code written
    Steps:
      1. Run `grep -n "AirPodsState" FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift` — should find struct definition and state dict
      2. Run `grep -n "macToUID\|uidToMAC" FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift` — should find correlation map
      3. Run `grep -n "setListeningMode\|refreshAirPodsState" FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift` — should find both methods
    Expected Result: All three patterns found
    Failure Indicators: Missing struct, map, or methods
    Evidence: .sisyphus/evidence/task-3-airpods-state.txt
  ```

  **Commit**: YES
  - Message: `feat: extend BluetoothDeviceMonitor with AirPods state tracking and device correlation`
  - Files: `BluetoothDeviceMonitor.swift`, `PairedBluetoothDevice.swift`
  - Pre-commit: `xcodebuild build`

- [x] 4. Show Disconnected Bluetooth Devices in Main Device List

  **What to do**:
  - In `MenuBarPopupView.swift`, move paired Bluetooth device display from edit-mode-only (lines 472-501) to the main device list
  - Show `PairedDeviceRow` entries below connected `DeviceRow` entries in the normal (non-edit) output view
  - Add a subtle visual separator or "Paired" section header between connected and disconnected devices
  - Ensure disconnected devices are visually distinct: dimmed icon opacity (0.6), secondary text color for name
  - Keep the existing edit mode behavior intact — paired devices should still appear in edit mode too
  - Handle edge cases:
    - Bluetooth is off: show "Turn on Bluetooth to connect devices" message (existing behavior, keep it)
    - Device is currently connecting: show spinner (existing PairedDeviceRow behavior, keep it)
    - Device just connected: remove from paired list (existing `notifyDeviceAppearedInCoreAudio` flow)
    - IOBluetooth/CoreAudio timing desync: keep existing name-based filter (`filteredPaired`)

  **Must NOT do**:
  - Do not refactor MenuBarPopupView into smaller files
  - Do not change the edit mode paired device behavior
  - Do not add any listening mode or battery UI (that's Tasks 5-7)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Modifying a 1110-line SwiftUI view requires surgical precision to avoid breaking existing behavior
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 5 and 6)
  - **Parallel Group**: Wave 2 (with Tasks 5, 6)
  - **Blocks**: Task 8
  - **Blocked By**: Task 3

  **References**:

  **Pattern References**:
  - `FineTune/Views/MenuBarPopupView.swift:472-501` — Current edit-mode-only paired device section (this code moves/duplicates to normal mode)
  - `FineTune/Views/MenuBarPopupView.swift:521-529` — Normal mode output device list (`ForEach(sortedDevices)`) — insert paired devices AFTER this section
  - `FineTune/Views/MenuBarPopupView.swift:482-483` — Existing name-based filter for IOBluetooth/CoreAudio desync: `let connectedNames = Set(editableDeviceOrder.map(\.name))`
  - `FineTune/Views/Rows/PairedDeviceRow.swift` — The existing row component (reuse as-is for normal mode)
  - `FineTune/Views/MenuBarPopupView.swift:49-52` — State vars for `pairedDevices` and `isBluetoothOn`

  **WHY Each Reference Matters**:
  - Lines 472-501: This is the exact block to replicate in normal mode. Copy the filtering logic and PairedDeviceRow instantiation.
  - Lines 521-529: This is WHERE to insert the paired devices section — after the `ForEach(sortedDevices)` that shows connected devices.
  - `PairedDeviceRow.swift`: Reuse unchanged. It already handles connecting state, spinner, and error display.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Disconnected devices visible in main list
    Tool: Bash
    Preconditions: Build succeeds
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -n "PairedDeviceRow" FineTune/Views/MenuBarPopupView.swift` — should appear in BOTH edit mode section AND normal mode section
      4. Count occurrences: should be at least 2 ForEach blocks rendering PairedDeviceRow
    Expected Result: PairedDeviceRow rendered in both normal and edit mode
    Failure Indicators: Only one PairedDeviceRow render site (still only in edit mode)
    Evidence: .sisyphus/evidence/task-4-paired-in-main.txt

  Scenario: Bluetooth-off state handled
    Tool: Bash
    Preconditions: Code written
    Steps:
      1. Run `grep -n "isBluetoothOn\|Turn on Bluetooth" FineTune/Views/MenuBarPopupView.swift` — should appear in normal mode section too
    Expected Result: Bluetooth-off message exists in normal mode output section
    Failure Indicators: Message only in edit mode
    Evidence: .sisyphus/evidence/task-4-bluetooth-off.txt
  ```

  **Commit**: YES
  - Message: `feat: show disconnected Bluetooth devices in main output device list`
  - Files: `MenuBarPopupView.swift`
  - Pre-commit: `xcodebuild build`

- [x] 5. Create ListeningModePicker Component

  **What to do**:
  - Create `FineTune/Views/Components/ListeningModePicker.swift` — a compact dropdown showing available listening modes
  - Use the existing `DropdownMenu` component as the base (see `DropdownMenu.swift` for API)
  - Props:
    - `availableModes: [ListeningMode]` — dynamic list of modes this device supports
    - `currentMode: ListeningMode?` — currently active mode (nil if unknown)
    - `onSelectMode: (ListeningMode) -> Void` — callback when user selects a mode
  - Visual design:
    - Trigger button: compact, shows current mode icon + abbreviated name (e.g., "ANC", "Trans.", "Adapt.")
    - Dropdown items: icon + full name for each mode (e.g., "Noise Cancellation", "Transparency", "Adaptive", "Off")
    - Match existing `AutoEQPicker` sizing and style
    - Width: ~90px trigger, ~160px popover
  - SF Symbols for modes:
    - Off: `ear`
    - Noise Cancellation: `ear.fill` (or `waveform.path.ecg`)
    - Transparency: `ear.and.waveform`
    - Adaptive: `wand.and.stars` (or `sparkles`)
  - Include SwiftUI Preview with all mode combinations (3-mode AirPods Max, 3-mode AirPods Pro 3, 4-mode AirPods Pro 2)

  **Must NOT do**:
  - Do not integrate into DeviceRow yet (that's Task 7)
  - Do not add state management — this is a pure presentation component
  - Do not hardcode mode lists — must accept dynamic `availableModes` array

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: Pure UI component creation matching existing design system
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4 and 6)
  - **Parallel Group**: Wave 2 (with Tasks 4, 6)
  - **Blocks**: Task 7
  - **Blocked By**: Task 2 (needs ListeningMode enum)

  **References**:

  **Pattern References**:
  - `FineTune/Views/Components/DropdownMenu.swift:1-50` — Reusable dropdown API: `items`, `selectedItem`, `maxVisibleItems`, `width`, `onSelect`, `label`, `itemContent`. Use this as the container.
  - `FineTune/Views/Components/AutoEQPicker.swift` — Existing picker built on DropdownMenu. Follow same patterns for sizing, styling, and integration approach.
  - `FineTune/Views/DesignSystem/DesignTokens.swift` — Design tokens for colors, spacing, typography. Use `DesignTokens.Typography.caption`, `DesignTokens.Colors.textSecondary`, etc.

  **API/Type References**:
  - `FineTune/Audio/Types/ListeningMode.swift` (from Task 2) — The enum with `displayName` and `iconName` properties

  **WHY Each Reference Matters**:
  - `DropdownMenu.swift`: This is the container component. Don't build a custom dropdown — use this and provide `label` and `itemContent` closures.
  - `AutoEQPicker.swift`: Shows the exact pattern for building a picker on top of DropdownMenu with proper sizing and design token usage.
  - `DesignTokens.swift`: All spacing/color/typography values come from here. Don't use raw values.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Component builds and uses DropdownMenu
    Tool: Bash
    Preconditions: Tasks 1-2 completed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -n "DropdownMenu" FineTune/Views/Components/ListeningModePicker.swift` — should use DropdownMenu
      4. Run `grep -n "availableModes" FineTune/Views/Components/ListeningModePicker.swift` — should accept dynamic mode list
    Expected Result: Build succeeds; component uses DropdownMenu and accepts dynamic modes
    Failure Indicators: Hardcoded mode list; custom dropdown instead of DropdownMenu
    Evidence: .sisyphus/evidence/task-5-picker-component.txt

  Scenario: Preview covers all device variants
    Tool: Bash
    Preconditions: Component created
    Steps:
      1. Run `grep -n "#Preview" FineTune/Views/Components/ListeningModePicker.swift` — should have preview
      2. Run `grep -c "ListeningMode\." FineTune/Views/Components/ListeningModePicker.swift` — should reference multiple modes
    Expected Result: Preview exists; multiple mode variants shown
    Failure Indicators: No preview or only one mode variant
    Evidence: .sisyphus/evidence/task-5-preview.txt
  ```

  **Commit**: YES
  - Message: `feat: add ListeningModePicker dropdown component`
  - Files: `ListeningModePicker.swift`
  - Pre-commit: `xcodebuild build`

- [x] 6. Add Battery Level Reading via IOKit

  **What to do**:
  - Add battery reading capability to `BluetoothDeviceMonitor` (or a new extension file `BluetoothDeviceMonitor+Battery.swift`):
    - `func readBatteryLevel(forMAC mac: String) -> Int?` — reads battery from IOKit
    - Uses `IOServiceMatching("AppleDeviceManagementHIDEventService")` to enumerate HID services
    - For each service, reads `BatteryPercent` (Int) and `DeviceAddress` (String — MAC address)
    - Matches `DeviceAddress` to the known MAC to get battery for specific AirPods
    - Returns nil if battery not available (device disconnected, no battery report)
  - Integrate into the `refreshAirPodsState` method from Task 3 — populate `batteryPercent` field of `AirPodsState`
  - Battery is read during the periodic 30s refresh (from Task 3's timer) — no separate timer needed
  - Handle edge cases:
    - Battery returns 0 or negative: treat as unavailable (return nil)
    - Device has no `BatteryPercent` property: return nil
    - Multiple HID services for same device: take the one with valid battery

  **Must NOT do**:
  - Do not show left/right/case breakdown — single percentage only
  - Do not add battery for non-AirPods devices
  - Do not add battery notifications or alerts
  - Do not build polling infrastructure — reuse Task 3's timer
  - Do not add any UI in this task (that's Task 7)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: IOKit interaction requires careful memory management (CF types, iterator lifecycle)
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4 and 5)
  - **Parallel Group**: Wave 2 (with Tasks 4, 5)
  - **Blocks**: Task 7
  - **Blocked By**: Task 3

  **References**:

  **Pattern References**:
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:197-207` — `runOnBTQueue` dispatch pattern (battery reads should also use a background queue, though IOKit doesn't require btQueue specifically)
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:212-216` — `RawPairedDevice` Sendable struct pattern — follow for any data transferred across actor boundaries

  **External References**:
  - Stack Overflow IOKit battery reading: https://stackoverflow.com/a/59730707 — Complete Swift implementation using `IOServiceMatching("AppleDeviceManagementHIDEventService")` with `BatteryPercent` and `DeviceAddress` properties
  - AirBattery (GitHub) — Production macOS app reading AirPods battery via IOKit

  **WHY Each Reference Matters**:
  - `runOnBTQueue` pattern: IOKit calls are relatively fast but should still run off-main-thread. Follow the existing dispatch pattern.
  - Stack Overflow reference: Complete working implementation of the exact IOKit query needed. Copy the pattern for `IOServiceGetMatchingServices` → iterate → `IORegistryEntryCreateCFProperty`.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Battery reading compiles and integrates
    Tool: Bash
    Preconditions: Task 3 completed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -rn "BatteryPercent\|AppleDeviceManagementHIDEventService" FineTune/` — should find IOKit battery code
      4. Run `grep -rn "batteryPercent" FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift` — should find integration point
    Expected Result: Build succeeds; battery reading code exists and integrates with AirPodsState
    Failure Indicators: Build failure; missing IOKit integration
    Evidence: .sisyphus/evidence/task-6-battery-build.txt

  Scenario: Battery edge cases handled
    Tool: Bash
    Preconditions: Code written
    Steps:
      1. Run `grep -n "nil\|<= 0\|unavailable" FineTune/` — look in battery reading code for nil handling
      2. Verify battery function returns optional Int (Int?) — not forced unwrap
    Expected Result: Function returns Int?; invalid values (0, negative) return nil
    Failure Indicators: Forced unwrap; non-optional return type
    Evidence: .sisyphus/evidence/task-6-battery-safety.txt
  ```

  **Commit**: YES
  - Message: `feat: add IOKit battery level reading for connected AirPods`
  - Files: `BluetoothDeviceMonitor.swift` (or new `BluetoothDeviceMonitor+Battery.swift`)
  - Pre-commit: `xcodebuild build`

- [x] 7. Integrate Listening Mode + Battery into DeviceRow

  **What to do**:
  - Modify `DeviceRow.swift` to accept optional AirPods props:
    - `airPodsState: AirPodsState?` — nil for non-AirPods devices (callers don't need to change)
    - `onListeningModeChange: ((ListeningMode) -> Void)?` — nil for non-AirPods
  - In DeviceRow body, if `airPodsState` is non-nil:
    - Show `ListeningModePicker` (from Task 5) in the header row, positioned between device name area and mute button
    - Show battery percentage next to device name as a subtitle (e.g., "85%") using `DesignTokens.Typography.caption` and `DesignTokens.Colors.textTertiary`
    - If battery is nil, show nothing (not "—" or "N/A")
    - If no available modes, hide the picker entirely
  - Modify `MenuBarPopupView.swift` to pass AirPods state from `audioEngine.bluetoothDeviceMonitor.connectedAirPodsState[device.uid]` to DeviceRow
  - Wire `onListeningModeChange` to call `audioEngine.bluetoothDeviceMonitor.setListeningMode(_:forDeviceUID:)`
  - Trigger `refreshAirPodsState` when popup becomes visible (on `NSWindow.didBecomeKeyNotification`)
  - Use existing `init` default parameter pattern from DeviceRow (all AirPods params default to nil) so existing call sites don't break

  **Must NOT do**:
  - Do not refactor DeviceRow into sub-components
  - Do not change the init signature for existing parameters
  - Do not add listening mode persistence

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: UI integration matching existing layout patterns precisely
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 8)
  - **Parallel Group**: Wave 3 (with Task 8)
  - **Blocks**: F1-F4
  - **Blocked By**: Tasks 5, 6

  **References**:

  **Pattern References**:
  - `FineTune/Views/Rows/DeviceRow.swift:43-86` — init with default parameters. Follow this pattern: add new AirPods params at the end with default nil values so existing call sites compile unchanged.
  - `FineTune/Views/Rows/DeviceRow.swift:95-153` — `deviceHeader` layout. The ListeningModePicker goes between the name VStack (line 116) and `if hasVolumeControl` (line 155).
  - `FineTune/Views/Rows/DeviceRow.swift:122-127` — AutoEQ subtitle pattern. Battery percentage follows the same subtitle approach below device name.
  - `FineTune/Views/MenuBarPopupView.swift:521-529` — Where DeviceRow is instantiated. Add `airPodsState` and `onListeningModeChange` params here.
  - `FineTune/Views/Components/ListeningModePicker.swift` (from Task 5) — The component to embed

  **WHY Each Reference Matters**:
  - `DeviceRow.swift:43-86`: The init uses default params extensively — AutoEQ params all default to nil. Follow this exact pattern for AirPods params.
  - `DeviceRow.swift:122-127`: The AutoEQ subtitle shows the pattern for adding a second line under device name. Battery goes here too.
  - `MenuBarPopupView.swift:521-529`: This is the call site. Must pass `connectedAirPodsState[device.uid]` without breaking existing parameters.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: DeviceRow builds with new AirPods params
    Tool: Bash
    Preconditions: Tasks 1-6 completed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -n "airPodsState" FineTune/Views/Rows/DeviceRow.swift` — should find property and init param
      4. Run `grep -n "ListeningModePicker" FineTune/Views/Rows/DeviceRow.swift` — should find usage in body
      5. Run `grep -n "batteryPercent\|battery" FineTune/Views/Rows/DeviceRow.swift` — should find battery display
    Expected Result: Build succeeds; DeviceRow has AirPods state, picker, and battery display
    Failure Indicators: Build failure; missing integration points
    Evidence: .sisyphus/evidence/task-7-device-row.txt

  Scenario: Existing call sites unbroken
    Tool: Bash
    Preconditions: Code written
    Steps:
      1. Run `grep -n "DeviceRow(" FineTune/Views/` — check all call sites
      2. Verify all existing DeviceRow instantiations compile (no new required params)
      3. Build must succeed — this confirms backward compatibility
    Expected Result: All existing DeviceRow call sites compile without changes
    Failure Indicators: Build errors at existing DeviceRow call sites
    Evidence: .sisyphus/evidence/task-7-backward-compat.txt
  ```

  **Commit**: YES
  - Message: `feat: integrate listening mode dropdown and battery into device row`
  - Files: `DeviceRow.swift`, `MenuBarPopupView.swift`
  - Pre-commit: `xcodebuild build`

- [x] 8. Connect-and-Select Flow for Disconnected Devices

  **What to do**:
  - Modify the `PairedDeviceRow` `onConnect` callback in `MenuBarPopupView.swift` (normal mode section from Task 4) to:
    1. Call `audioEngine.bluetoothDeviceMonitor.connect(device: device)` (existing)
    2. After connection succeeds (device appears in CoreAudio), automatically set it as the default output device
  - Implementation approach:
    - Add a `pendingAutoSelect: Set<String>` state in `MenuBarPopupView` (keyed by MAC address)
    - On connect click: insert MAC into `pendingAutoSelect`, then call `connect(device:)`
    - In the existing `onChange(of: audioEngine.outputDevices)` handler: check if any newly appeared device matches a `pendingAutoSelect` MAC (via the `macToUID` map from Task 3). If yes, call `audioEngine.setDefaultOutputDevice(device.id)` and remove from pending set.
    - Clear pending on timeout (12s — matches existing connect timeout)
  - Handle edge cases:
    - Connection fails: `pendingAutoSelect` is cleared by timeout, no auto-select happens
    - Device connects but user manually selects another device before auto-select triggers: clear pending for that MAC
    - Multiple connects in flight: each tracked independently

  **Must NOT do**:
  - Do not add retry logic beyond existing 12s timeout
  - Do not change AudioEngine.setDefaultOutputDevice behavior
  - Do not add auto-connect on app launch

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: State machine logic with race conditions between Bluetooth connection and CoreAudio device appearance
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 7)
  - **Parallel Group**: Wave 3 (with Task 7)
  - **Blocks**: F1-F4
  - **Blocked By**: Task 4

  **References**:

  **Pattern References**:
  - `FineTune/Views/MenuBarPopupView.swift:141-146` — `onChange(of: audioEngine.outputDevices)` handler. This is WHERE to check for pending auto-select.
  - `FineTune/Audio/Engine/AudioEngine.swift:850-858` — `setDefaultOutputDevice(_:)` — the method to call for auto-selecting the newly connected device
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:132-159` — `connect(device:)` flow. After `openConnection()` succeeds, the device appears in CoreAudio and `notifyDeviceAppearedInCoreAudio()` is called, which triggers `onChange(of: audioEngine.outputDevices)`.
  - `FineTune/Audio/Engine/AudioEngine.swift:56-59` — `PriorityState` state machine. Understand this to avoid conflicts with the existing auto-switch logic.
  - `FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift:260-268` — Existing timeout pattern (12s). Match this for auto-select timeout.

  **WHY Each Reference Matters**:
  - `MenuBarPopupView.swift:141-146`: The exact hook point. When output devices change and a pending auto-select exists, set the new device as default.
  - `AudioEngine.swift:850-858`: Call this to set default — it handles echo tracking, confirmed UID, and follow-default routing.
  - `AudioEngine.swift:56-59`: The priority state machine may interfere. If auto-switch is pending, the new device might get overridden. Understand this to avoid conflicts.

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Connect-and-select logic exists
    Tool: Bash
    Preconditions: Task 4 completed
    Steps:
      1. Run `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' 2>&1 | tail -5`
      2. Verify "BUILD SUCCEEDED"
      3. Run `grep -n "pendingAutoSelect\|setDefaultOutputDevice" FineTune/Views/MenuBarPopupView.swift` — should find both
      4. Run `grep -n "pendingAutoSelect" FineTune/Views/MenuBarPopupView.swift | wc -l` — should be >= 3 (declaration, insert, check)
    Expected Result: Build succeeds; auto-select state management exists with set-default call
    Failure Indicators: Build failure; missing auto-select logic
    Evidence: .sisyphus/evidence/task-8-connect-select.txt

  Scenario: Timeout cleanup exists
    Tool: Bash
    Preconditions: Code written
    Steps:
      1. Run `grep -n "timeout\|12\|clear.*pending\|remove.*pending" FineTune/Views/MenuBarPopupView.swift` — should find timeout cleanup
    Expected Result: Pending auto-select is cleared on timeout
    Failure Indicators: No timeout handling for pendingAutoSelect
    Evidence: .sisyphus/evidence/task-8-timeout.txt
  ```

  **Commit**: YES
  - Message: `feat: auto-select device as output after connecting from main list`
  - Files: `MenuBarPopupView.swift`
  - Pre-commit: `xcodebuild build`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
>
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, check code). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `xcodebuild build`. Review all changed files for: `as! Any`, forced unwraps on private API calls, missing `responds(to:)` guards, IOBluetooth calls not on btQueue, `perform(_:with:)` usage for listeningMode (FORBIDDEN). Check for console.log/print statements that should be Logger calls.
  Output: `Build [PASS/FAIL] | Guards [N/N complete] | Queue Safety [PASS/FAIL] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Test cross-task integration: connect disconnected AirPods → verify it appears as connected → verify listening mode dropdown appears → verify battery shows. Test edge cases: Bluetooth off state, non-AirPods device. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance. Detect cross-task contamination. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

| # | Message | Files | Pre-commit |
|---|---------|-------|------------|
| 1 | `chore: verify dev setup and project build` | — (no changes, just verification) | `xcodebuild build` |
| 2 | `feat: add IOBluetooth private API bridging header and extensions` | `FineTune-Bridging-Header.h`, `BluetoothDeviceMonitor+AirPods.swift`, Xcode project config | `xcodebuild build` |
| 3 | `feat: extend BluetoothDeviceMonitor with AirPods capabilities` | `BluetoothDeviceMonitor.swift`, `PairedBluetoothDevice.swift` | `xcodebuild build` |
| 4 | `feat: show disconnected Bluetooth devices in main device list` | `MenuBarPopupView.swift` | `xcodebuild build` |
| 5 | `feat: add ListeningModePicker dropdown component` | `ListeningModePicker.swift` | `xcodebuild build` |
| 6 | `feat: add battery level reading for connected AirPods` | `BluetoothDeviceMonitor.swift` or new extension | `xcodebuild build` |
| 7 | `feat: integrate listening mode and battery into device row` | `DeviceRow.swift`, `MenuBarPopupView.swift` | `xcodebuild build` |
| 8 | `feat: connect-and-select flow for disconnected devices` | `MenuBarPopupView.swift`, `AudioEngine.swift` | `xcodebuild build` |

---

## Success Criteria

### Verification Commands
```bash
xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS'  # Expected: BUILD SUCCEEDED
```

### Final Checklist
- [ ] All "Must Have" items present
- [ ] All "Must NOT Have" items absent
- [ ] Build succeeds with zero errors
- [ ] Disconnected devices visible in main list
- [ ] Click-to-connect works and auto-selects device
- [ ] Listening mode dropdown works for connected AirPods
- [ ] Battery percentage displays for connected AirPods
- [ ] Private API calls all guarded with `responds(to:)`
- [ ] All IOBluetooth calls on `btQueue`

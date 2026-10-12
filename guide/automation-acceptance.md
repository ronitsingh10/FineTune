# Automation acceptance record

## Automated verification

The current change is checked with the macOS Xcode hosted unit suite, plus transport and control tests. Tests include protocol/range validation, active/inactive app controls, shared app identity, legacy URLs, routing validation, EQ patching and presets, preferences, presentation state, pending operations, batch errors, stale revisions, subscriptions, socket framing, private discovery, real socket roundtrip, enable/disable/reset cleanup, and duplicate instance protection.

The additional Stream Deck repository tests connection negotiation/reconnect/no replay, command validation, dial accumulation, shared group settings, EQ/correction feedback, scene partial failures, package resources and property-inspector forms for the actual exported API catalog.

## Manual hardware acceptance

The target device is Stream Deck XL. The supplied starter profile has 32 keys. Physical dial/touch acceptance requires a dial-equipped device and remains separate.

Before marking real audio acceptance complete, record all of these with the final custom build:

- At least two output devices and at least five apps playing simultaneously, as required by CONTRIBUTING.md.
- Actual key presses, current-state feedback, app volume/mute/boost, default selection, single/multi/default routing, and inactive persistence.
- Device disconnect during playback and restoration after reconnect.
- Input volume/mute where supported, input-lock preference, DDC/hardware/software volume tiers where available.
- EQ bands/presets, AutoEQ selection/import/favorites/preamp, loudness and alert volume.
- API disabled/re-enabled, app restart, missing targets and error indicators.
- Repeat profile setup through the supplied selectors; no URL or shell-script buttons.
- Ordinary command/readback p95 target under 150 ms and feedback target under 200 ms; record hardware/profile-download exclusions and actual playback stability.

Unavailable hardware, permission-gated checks and unmeasured latency must be labeled. Automated tests and packaging do not prove physical audio behavior.

# Output device lock

Enable **Settings → Audio → Lock Output Device** to keep managed, single-output
apps on the selected output. The option is off by default.

If that device disconnects, FineTune keeps those apps silent instead of playing
them through a fallback speaker. When the device reconnects, FineTune rebuilds
the output and restores the app's existing volume and mute state. Selecting a
different default output inside FineTune moves the lock to that device.

The lock covers apps following the system default and apps explicitly assigned
to the locked device. Explicit multi-output selections, ignored apps and apps
assigned to other devices keep their existing routing behavior. It does not
pause playback in the source application or promise system-wide silence: system
sounds and audio emitted before a newly started process is discovered are
outside this scope. If source protection or output restoration fails, the Audio
settings show the error; existing protection is retained where available.

## Testing

`FineTuneHeadlessUnitTests` is a separate shared scheme for hosted unit tests. Its
`FINETUNE_HEADLESS_TESTS=1` entry point bypasses normal application startup,
audio monitoring, permissions and UI activation. The existing `FineTune` scheme
is unchanged.

Focused coverage is in `AudioEngineOutputLockTests`, `ProcessTapOutputGuardTests`
and `OutputLockSettingsTests`. Before release, also validate physical device
hot-plug, multiple simultaneously playing apps, sleep/wake and interactions
with explicit multi-output routes. Mock tests cannot establish those hardware
behaviors.

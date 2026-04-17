# Troubleshooting

## No sound / audio stops working

FineTune requires the **Screen & System Audio Recording** permission to capture and route app audio.

1. Open **System Settings** → **Privacy & Security** → **Screen & System Audio Recording**
2. Find FineTune in the list and enable it
3. **Restart FineTune** — the permission doesn't take effect until relaunch

If you previously denied the permission prompt, you'll need to enable it manually from System Settings.

## App not appearing

FineTune only shows apps that are **actively playing audio**. If an app isn't visible:

- Make sure the app is actually producing sound (start playback)
- Check if the app is hidden. Open **edit mode** (pencil icon) and look for the eye icon next to the app name. A crossed-out eye means the app is being ignored.
- Some apps use helper processes for audio. Try restarting the app.

## App causing audio issues

Some apps don't work well with CoreAudio process taps — particularly audio processors, DAWs, VoIP tools, and apps that do their own low-level audio routing. Symptoms include distorted audio, echo, or audio cutting out.

**Fix:** Open **edit mode** (pencil icon) and click the eye icon to ignore the problematic app. This tears down the process tap entirely for that app, so it goes back to normal macOS audio routing.

Common apps that may need to be ignored:
- Audio Hijack, Loopback, and other Rogue Amoeba apps
- Some VoIP/conferencing tools with custom audio engines
- FaceTime, WhatsApp, and other calling apps (tapping can break echo cancellation, causing volume ducking)

## Volume slider not working

Some apps use helper processes to play audio rather than the main app process. The slider you see might be controlling the wrong process.

**Fix:** Try restarting the app. If the issue persists, check edit mode to see if the app appears as a different process name.

## Audio device not switching automatically

FineTune uses a **device priority list** to decide which output device to use. When a device connects, FineTune only switches to it if it's ranked higher than the current device. When a device disconnects, FineTune falls back to the next highest-priority device that's still connected.

If you want newly connected outputs to take over immediately regardless of priority, enable **Settings → Audio → Auto-Switch New Output**.

By default, devices are added to the bottom of the list in the order they're first seen. Since your Mac's built-in speakers are always connected, they end up at the top (highest priority), so FineTune won't auto-switch to headphones, external speakers, or other devices when they connect.

**This is a one-time setup.** Once you set your preferred order, it's saved permanently and works across app restarts.

**How to reorder:**

1. Click the **pencil icon** in the menu bar popup to enter edit mode
2. **Drag** devices to reorder, or **click the priority number** and type a new position
3. Click the **checkmark** to exit edit mode — your order is saved

The device at position 1 has the highest priority. FineTune will always prefer the highest-priority device that's currently connected.

Input and output devices have **separate priority lists** — switch between them using the tabs in edit mode.

> **Note:** For AirPods, taking them out of your ears and putting them back in (without the case) is handled by macOS Automatic Ear Detection. FineTune doesn't interfere with that.

## Input devices not showing

FineTune's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find FineTune and enable it
3. Restart FineTune

## EQ not applying / sounds the same

- The EQ is enabled by default. Check that the **toggle switch** in the EQ panel header is on.
- The default preset is **Flat** (all bands at 0 dB), which makes no audible changes. Select a different preset or adjust the bands manually.
- EQ is **per-app**, not per-device. Make sure you're adjusting the EQ for the correct app.
- If using AutoEQ headphone correction, that's separate from the 10-band EQ. Verify a profile is assigned to the correct device via the wand icon

## Audio quality sounds degraded

- Check if volume boost is set above 1x — high boost levels can cause clipping on loud passages
- If using EQ, large boosts across multiple bands can push levels too high. Try pulling bands down instead of boosting others up.
- AutoEQ profiles include a preamp gain reduction to prevent clipping; manual EQ does not, so be mindful of total gain
- Try resetting the app to defaults: `open "finetune://reset"` in Terminal

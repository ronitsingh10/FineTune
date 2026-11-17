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

There are two cases.

**Per-app slider.** Some apps use helper processes to play audio rather than the main app process, so the slider you see might be controlling the wrong process. Try restarting the app. If the issue persists, check edit mode to see if the app appears as a different process name.

**Per-device slider.** When you open a device, FineTune picks a volume backend automatically:

- **Hardware**: the device reports a native volume control (most USB DACs, AirPods, built-in speakers).
- **DDC**: an external display that responds to the monitor-control protocol.
- **Software**: FineTune attenuates inside its own audio graph.

Auto-detection gets it right for most devices, but some USB DACs and HDMI/DisplayPort outputs advertise a hardware slider that doesn't actually move the output level. If the device slider doesn't change the volume, open the device inspector (the info button on the device row) and turn on **Software volume**. FineTune remembers the choice per device. The toggle is hidden when auto-detect already picked Software, because there's no alternative backend to switch to.

## Audio device not switching automatically

FineTune follows **macOS output switching by default**, including switches to AirPods. In **Settings → Audio**, leave **Output Device Priority** off to let macOS choose the output when devices connect or disconnect. The setting also defaults to off when upgrading from a version without this option; your saved device order is retained.

You can also toggle output priority with the small **up/down arrows** button next to the pencil in the popup header. Gray means macOS controls switching; the accent-colored button means FineTune's priority order is enabled. Hover over it to see the current mode.

If the system output changes but a particular app stays on another device, choose **System Audio** in that app's output picker. Apps assigned to a specific device or multiple devices keep their explicit routing independently of the output priority setting.

To have FineTune manage output switching, enable **Output Device Priority**. FineTune then uses your device order when devices connect and falls back to the highest-priority available device on disconnect. A lower-priority device connecting can have macOS's automatic switch reversed. New devices are appended to the list, so move headphones above the built-in speakers if you want to prefer them.

**How to configure the order:**

1. Connect the devices you want to reorder
2. Click the **pencil icon** in the menu bar popup to enter edit mode
3. In the **Output** tab, **drag** devices to reorder, or **click the priority number** and type a new position
4. Click the **checkmark** to exit edit mode — your order is saved
5. Enable **Settings → Audio → Output Device Priority**

Position 1 has the highest priority. Enabling the setting immediately selects the highest-priority available output. Turning it off keeps the current system output and lets future macOS switches pass through. Reordering alone does not enable output priority.

Input and output devices have **separate priority lists**. **Lock Input Device** controls microphone switching separately; it does not control output switching.

## Input devices not showing

FineTune's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find FineTune and enable it
3. Restart FineTune

## Media keys don't control FineTune

Media keys (F10 / F11 / F12) are opt-in and require the **Accessibility** permission so FineTune can observe the keystrokes.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable FineTune in the list. If it's already on, toggle it off and back on to clear a rare permission-bootstrap race.
3. Open FineTune Settings → **Media Keys & HUD**, turn on **Control volume with media keys**, and pick a HUD style (Tahoe or Classic) or disable the HUD

If the keys still don't work right after launch, a WindowServer handoff can briefly swallow the first keypress. Try once more; subsequent presses are reliable.

## Volume HUD not appearing

- Check Settings → **Media Keys & HUD**. The HUD is off by default and has to be enabled separately from the media-key toggle.
- Switch HUD styles if one isn't rendering. Tahoe uses macOS 26's system HUD look; Classic matches the older translucent rounded-rect style.

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

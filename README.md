<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="FineTune Icon">
</p>

# FineTune

Per-application audio control for macOS. Set individual volume levels, route apps to different output devices, and apply EQ from your menu bar.

![FineTune Screenshot](assets/screenshot.png)

## Download

**[Download FineTune v1.0.0](https://github.com/ronitsingh10/FineTune/releases/latest)**

## Features

- Per-app volume control with mute
- Per-device volume control with mute
- Route apps to different output devices
- 10-band equalizer with 20 presets across 5 categories
- Real-time VU meters
- Volume boost up to 200%
- Quick device switching
- Click app icon to bring app to front
- Settings persist across restarts

## How It Works

FineTune uses macOS Core Audio process taps to intercept and modify audio streams before they reach your output devices. This allows precise control without affecting the source applications.

## Why FineTune?

macOS doesn't have built-in per-app audio control. FineTune fills that gap.
If you find it useful, consider contributing — whether that's code, bug reports, or just spreading the word.

## Requirements

- macOS 14.0 (Sonoma) or later
- Audio capture permission (prompted on first launch)

## Build from Source

```bash
git clone https://github.com/ronitsingh10/FineTune.git
cd FineTune
open FineTune.xcodeproj
```

Select your development team in Signing & Capabilities, then build and run (Cmd+R).

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

GPL v3. See [LICENSE](LICENSE) for details.

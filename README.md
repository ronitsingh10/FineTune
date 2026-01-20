<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="FineTune app icon">
</p>

<h1 align="center">FineTune</h1>

<p align="center">
  <strong>Per-app volume control for macOS</strong>
</p>

<p align="center">
  <a href="https://github.com/ronitsingh10/FineTune/releases/latest"><img src="https://img.shields.io/github/v/release/ronitsingh10/FineTune" alt="Latest Release"></a>
  <a href="https://github.com/ronitsingh10/FineTune/releases"><img src="https://img.shields.io/github/downloads/ronitsingh10/FineTune/total" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-brightgreen" alt="macOS 14+"></a>
</p>

<p align="center">
  The volume mixer macOS should have built in.<br>
  Free and open-source.
</p>

---

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune showing per-app volume control with EQ and multi-device output" width="750">
</p>

## Features

- **Per-app volume** — Individual sliders and mute for each application
- **Multi-device output** — Route audio to multiple devices simultaneously
- **Input device control** — Monitor and adjust microphone levels
- **10-band EQ** — 20 presets across 5 categories
- **Pinned apps** — Pre-configure apps before they play
- **Audio routing** — Send apps to different outputs or follow system default
- **Volume boost** — Amplify up to 400%
- **Menu bar app** — Lightweight, always accessible
- **URL schemes** - Cross app scripting for device switching and per app volume

<p align="center">
  <img src="assets/screenshot-input.png" alt="FineTune input device control" width="400">
  <img src="assets/screenshot-settings.png" alt="FineTune settings panel" width="400">
</p>

## Install

**Homebrew** (recommended)

```bash
brew install --cask finetune
```

**Manual** — [Download latest release](https://github.com/ronitsingh10/FineTune/releases/latest)

## Why FineTune?

macOS has no built-in per-app volume control. Your music is too loud while a podcast is too quiet. FineTune fixes that:

- Turn down notifications without touching your music
- Play different apps on different speakers
- Boost quiet apps, tame loud ones
- Free forever, no subscriptions

## Requirements

- macOS 14.0 (Sonoma) or later
- Audio capture permission (prompted on first launch)

## FAQ

<details>
<summary><strong>App not appearing?</strong></summary>
Only apps actively playing audio show up. Start playback first.
</details>

<details>
<summary><strong>Volume slider not working?</strong></summary>
Some apps use helper processes. Try restarting the app.
</details>

<details>
<summary><strong>Input devices not showing?</strong></summary>
Grant microphone permission in System Settings → Privacy & Security → Microphone.
</details>

## Contributing

- ⭐ **Star this repo** — Help others discover FineTune
- 🐛 **Report bugs** — [Open an issue](https://github.com/ronitsingh10/FineTune/issues)
- 💻 **Contribute code** — See [CONTRIBUTING.md](CONTRIBUTING.md)

## Build from Source

```bash
git clone https://github.com/ronitsingh10/FineTune.git
cd FineTune
open FineTune.xcodeproj
```

## License

[GPL v3](LICENSE)

<img src="assets/icon.png" width="170" height="170" alt="FineTune app icon" align="left"/>

<h3>FineTune</h3>

Control the volume of every app independently, boost quiet ones up to 4x, route audio to different speakers, and shape your sound with EQ and headphone correction. Lives in your menu bar. Free and open-source.

<a href="https://github.com/ronitsingh10/FineTune/releases/download/v1.4.1/FineTune-1.4.1.dmg"><img src="assets/download-badge.svg" alt="Download for macOS" height="48"/></a>

<br clear="all"/>

<p align="center">
  <a href="https://github.com/ronitsingh10/FineTune/releases/latest"><img src="https://img.shields.io/github/v/release/ronitsingh10/FineTune?style=for-the-badge&labelColor=1c1c1e&color=0A84FF&logo=github&logoColor=white" alt="Latest Release"></a>
  <a href="https://github.com/ronitsingh10/FineTune/releases"><img src="https://img.shields.io/github/downloads/ronitsingh10/FineTune/total?style=for-the-badge&labelColor=1c1c1e&color=3a3a3c" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-3a3a3c?style=for-the-badge&labelColor=1c1c1e" alt="License: GPL v3"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15+"></a>
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune showing per-app volume control with EQ and multi-device output" width="750">
</p>

## Install

**Homebrew** (recommended)

```bash
brew install --cask finetune
```

**Manual** — [Download latest release](https://github.com/ronitsingh10/FineTune/releases/latest)

## Quick Start

1. Install FineTune and launch it from your Applications folder
2. Grant **Screen & System Audio Recording** permission when prompted
3. Click the FineTune icon in your menu bar. Apps playing audio appear automatically.

That's it. Adjust sliders, route audio, and explore EQ from the menu bar.

> **Tip:** Want FineTune to auto-switch to a specific device when you connect it? Open edit mode (pencil icon) and drag it above the built-in speakers. This is a one-time setup. Your preferred order is saved permanently.

## Features

### 🎚 Volume Control
- **Per-app volume** — Individual sliders and mute for each application
- **Per-app volume boost** — 2x / 3x / 4x gain presets
- **Pinned apps** — Keep apps visible in the menu bar even when they're not playing, so you can configure volume, EQ, and routing in advance
- **Ignore apps** — Completely disengage FineTune from specific apps. Tears down the audio tap so the app returns to normal macOS audio

### 🔀 Audio Routing
- **Multi-device output** — Route audio to multiple devices simultaneously
- **Audio routing** — Send apps to different outputs or follow system default
- **Device priority** — Choose which device FineTune switches to when a new device connects; auto-fallback on disconnect
- **Auto-restore** — When a device reconnects, apps automatically return to it with their volume, routing, and EQ intact

### 🎛 EQ & Correction
- **10-band EQ** — 20 presets across 5 categories
- **AutoEQ headphone correction** — Search thousands of headphone profiles or import your own ParametricEQ.txt files for per-device frequency response correction

### 🖥 Devices & System
- **Input device control** — Monitor and adjust microphone levels
- **Bluetooth device management** — Connect paired devices directly from the menu bar
- **Monitor speaker control** — Adjust volume on external displays via DDC
- **Menu bar app** — Lightweight, always accessible
- **URL schemes** — Automate volume, mute, device routing, and more from scripts

## Screenshots

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune showing per-app volume control with EQ and multi-device output" width="400">
  <img src="assets/screenshot-edit-mode.png" alt="FineTune edit mode showing device priority, Bluetooth pairing, and app pin/ignore controls" width="400">
</p>
<p align="center">
  <img src="assets/screenshot-autoeq.png" alt="FineTune AutoEQ headphone correction picker with search and favorites" width="400">
  <img src="assets/screenshot-settings.png" alt="FineTune settings panel" width="400">
</p>

## Documentation

- **[AutoEQ & Headphone Correction](guide/autoeq.md)** — Apply frequency correction from the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project, import [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) profiles, or browse [autoeq.app](https://www.autoeq.app/)
- **[URL Schemes](guide/url-schemes.md)** — Automate FineTune from Terminal, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or scripts
- **[Troubleshooting](guide/troubleshooting.md)** — Permission issues, missing apps, audio problems

## Contributing

- **Star this repo** — Help others discover FineTune
- **Report bugs** — [Open an issue](https://github.com/ronitsingh10/FineTune/issues)
- **Contribute code** — See [CONTRIBUTING.md](CONTRIBUTING.md)

### Build from Source

```bash
git clone https://github.com/ronitsingh10/FineTune.git
cd FineTune
open FineTune.xcodeproj
```

## Requirements

- macOS 15.0 (Sequoia) or later
- Audio capture permission (prompted on first launch)

## License

[GPL v3](LICENSE)

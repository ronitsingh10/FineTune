# URL Schemes

Control FineTune from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or any app that can open URLs. This makes it easy to automate volume changes, build keyboard shortcuts, or integrate FineTune into your workflow.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume of an application | `finetune://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set volume (0–100, or up to 400 with boost) |
| Set volume of audio device | `finetune://set-volumes?device=NAME&volume=PERCENT` | Set volume (0–100) |
| Step volume | `finetune://step-volume?app=BUNDLE_ID&direction=up` | Nudge volume up or down by ~5% |
| Set mute | `finetune://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute an app |
| Toggle mute | `finetune://toggle-mute?app=BUNDLE_ID` | Toggle mute state |
| Set device | `finetune://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an app to a specific output |
| Reset | `finetune://reset` | Reset all apps to 100% and unmuted |

## Examples

```bash
# Set Spotify to 50% volume
open "finetune://set-volumes?app=com.spotify.client&volume=50"

# Set different volumes for different apps at once
open "finetune://set-volumes?app=com.spotify.client&volume=80&app=com.hnc.Discord&volume=40"

# Mute multiple apps at once
open "finetune://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"

# Step Discord volume down
open "finetune://step-volume?app=com.hnc.Discord&direction=down"

# Set volume of Macbook Pro Speakers to 75%
open "finetune://set-volumes?device=MacBook Pro Speakers&volume=75"

# Set volume of AirPods to 30%
open "finetune://set-volumes?device=AirPods ✌️✌️&volume=30"


# Set Macbook Pro Speakers and AirPods to 10%
open "finetune://set-volumes?device=MacBook Pro Speakers&volume=10&device=AirPods ✌️✌️&volume=30"


# Route an app to a specific device
open "finetune://set-device?app=com.spotify.client&device=YOUR_DEVICE_UID"

# Reset everything
open "finetune://reset"
```

## Use Cases

**Meeting mode** — Mute everything except your video call app:

```bash
open "finetune://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"
```

**Focus playlist** — Set music to a low background level and silence notifications:

```bash
open "finetune://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup** — Boost a game and lower Discord:

```bash
open "finetune://set-volumes?app=com.game.example&volume=400&app=com.hnc.Discord&volume=40"
```

These commands work in Terminal, shell scripts, Automator, Raycast script commands, macOS Shortcuts (using "Open URL"), and any other tool that can open URLs.

## Finding Bundle IDs

App names shown in FineTune map to bundle IDs. Common ones:

| App | Bundle ID |
|-----|-----------|
| Spotify | `com.spotify.client` |
| Apple Music | `com.apple.Music` |
| Chrome | `com.google.Chrome` |
| Safari | `com.apple.Safari` |
| Discord | `com.hnc.Discord` |
| Slack | `com.tinyspeck.slackmacgap` |
| Zoom | `us.zoom.xos` |
| Firefox | `org.mozilla.firefox` |
| Arc | `company.thebrowser.Browser` |

To find any app's bundle ID:

```bash
osascript -e 'id of app "App Name"'
```

## Finding Device UIDs

In FineTune, click the pencil icon to enter edit mode, then click the copy button next to a device name to copy its UID.

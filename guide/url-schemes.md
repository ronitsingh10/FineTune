# URL Schemes

Control FineTune from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), [Elgato Stream Deck](https://www.elgato.com/stream-deck) (Open URL / Website action), or any app that can open URLs.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume | `finetune://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set app volume (0–100) |
| Set group volume | `finetune://set-volumes?group=NAME&volume=PERCENT` | Set a group's shared volume (0–100) |
| Step volume | `finetune://step-volume?app=BUNDLE_ID&direction=up` | Nudge app volume up or down by ~5% |
| Step group volume | `finetune://step-volume?group=NAME&direction=down` | Nudge a group's shared volume |
| Set mute | `finetune://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute an app |
| Set group mute | `finetune://set-mute?group=NAME&muted=true` | Mute or unmute a group |
| Toggle mute | `finetune://toggle-mute?app=BUNDLE_ID` | Toggle app mute |
| Toggle group mute | `finetune://toggle-mute?group=NAME` | Toggle group mute |
| Set device | `finetune://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an app to a specific output |
| Set group device | `finetune://set-device?group=NAME&device=DEVICE_UID` | Route a group (`device=default` follows system) |
| Reset | `finetune://reset` | Reset all apps and groups to 100% and unmuted |

You can mix `app` and `group` parameters in the same URL where noted (e.g. set several volumes at once).

Groups are matched by **name** (case-insensitive) or by **UUID**.

## Examples

```bash
# Set Spotify to 50% volume
open "finetune://set-volumes?app=com.spotify.client&volume=50"

# Set a Voice group to 40% (and Spotify separately)
open "finetune://set-volumes?group=Voice&volume=40&app=com.spotify.client&volume=80"

# Mute / unmute a group (great for Stream Deck)
open "finetune://toggle-mute?group=Voice"

# Step Discord volume down
open "finetune://step-volume?app=com.hnc.Discord&direction=down"

# Step the Voice group up
open "finetune://step-volume?group=Voice&direction=up"

# Route a group to a device, or back to system default
open "finetune://set-device?group=Voice&device=YOUR_DEVICE_UID"
open "finetune://set-device?group=Voice&device=default"

# Reset everything (apps + groups)
open "finetune://reset"

# Reset just one group
open "finetune://reset?group=Voice"
```

## Stream Deck

1. Keep FineTune running.
2. Add a **Website** / **Open** / **System → Website** action on a key.
3. Set the URL to a `finetune://…` action, for example:
   - `finetune://toggle-mute?group=Voice`
   - `finetune://step-volume?group=Voice&direction=up`
   - `finetune://set-volumes?group=Voice&volume=50`

Optional: use a multi-action key for “meeting mode” (mute music apps + raise Voice).

## Use Cases

**Meeting mode** — Mute everything except your voice-chat group:

```bash
open "finetune://set-mute?app=com.spotify.client&muted=true&group=Voice&muted=false"
```

**Focus playlist** — Set music low and silence notifications:

```bash
open "finetune://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup** — Boost a game and lower the Voice group:

```bash
open "finetune://set-volumes?app=com.game.example&volume=100&group=Voice&volume=40"
```

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

In FineTune, click the pencil icon to enter edit mode, tap the **info button** on a device row to open the device inspector, then click the copy button next to the UID to put it on the clipboard.

## Finding Group Names

Group names are whatever you set in edit mode (e.g. `Voice`). They are matched case-insensitively in URL schemes.

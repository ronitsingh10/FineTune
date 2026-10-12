# Automation command coverage

API version 1. This catalog describes implemented operations, not a claim of hardware acceptance.

| Method | Configuration | Validation |
|---|---|---|
| `api.describe` | None | Service validation; typed plugin form; hardware checks where applicable |
| `state.get` | None | Service validation; typed plugin form; hardware checks where applicable |
| `events.subscribe` | None | Service validation; typed plugin form; hardware checks where applicable |
| `operation.get` | operationId | Service validation; typed plugin form; hardware checks where applicable |
| `batch.execute` | commands, continueOnError | Service validation; typed plugin form; hardware checks where applicable |
| `app.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `app.get` | target | Service validation; typed plugin form; hardware checks where applicable |
| `app.volume.set` | target, percent | Service validation; typed plugin form; hardware checks where applicable |
| `app.volume.step` | target, domain, delta | Service validation; typed plugin form; hardware checks where applicable |
| `app.mute.set` | target, muted | Service validation; typed plugin form; hardware checks where applicable |
| `app.mute.toggle` | target | Service validation; typed plugin form; hardware checks where applicable |
| `app.boost.set` | target, boost | Service validation; typed plugin form; hardware checks where applicable |
| `app.boost.cycle` | target | Service validation; typed plugin form; hardware checks where applicable |
| `app.audio.reset` | target | Service validation; typed plugin form; hardware checks where applicable |
| `device.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `device.get` | target | Service validation; typed plugin form; hardware checks where applicable |
| `device.volume.set` | target, percent | Service validation; typed plugin form; hardware checks where applicable |
| `device.volume.step` | target, delta | Service validation; typed plugin form; hardware checks where applicable |
| `device.mute.set` | target, muted | Service validation; typed plugin form; hardware checks where applicable |
| `device.mute.toggle` | target | Service validation; typed plugin form; hardware checks where applicable |
| `device.default.set` | target | Service validation; typed plugin form; hardware checks where applicable |
| `device.hidden.set` | target, hidden | Service validation; typed plugin form; hardware checks where applicable |
| `device.priority.set` | direction, deviceUIDs | Service validation; typed plugin form; hardware checks where applicable |
| `device.icon.set` | target, symbol | Service validation; typed plugin form; hardware checks where applicable |
| `device.icon.clear` | target | Service validation; typed plugin form; hardware checks where applicable |
| `device.volumeBackend.set` | target, backend | Service validation; typed plugin form; hardware checks where applicable |
| `device.sampleRate.set` | target, sampleRate | Service validation; typed plugin form; hardware checks where applicable |
| `input.lock.set` | enabled, deviceUID | Service validation; typed plugin form; hardware checks where applicable |
| `alert.volume.set` | percent | Service validation; typed plugin form; hardware checks where applicable |
| `alert.volume.step` | delta | Service validation; typed plugin form; hardware checks where applicable |
| `alert.routing.set` | followDefault, deviceUID | Service validation; typed plugin form; hardware checks where applicable |
| `app.routing.set` | target, mode, deviceUIDs, allowOffline | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.setEnabled` | target, enabled | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.toggle` | target | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.band.set` | target, band, gainDB | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.band.step` | target, band, delta | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.setBands` | target, bandGains | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.reset` | target | Service validation; typed plugin form; hardware checks where applicable |
| `app.eq.preset.apply` | target, presetId | Service validation; typed plugin form; hardware checks where applicable |
| `eq.preset.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `eq.preset.create` | name, bandGains | Service validation; typed plugin form; hardware checks where applicable |
| `eq.preset.rename` | presetId, name | Service validation; typed plugin form; hardware checks where applicable |
| `eq.preset.delete` | presetId | Service validation; typed plugin form; hardware checks where applicable |
| `preferences.get` | None | Service validation; typed plugin form; hardware checks where applicable |
| `preferences.patch` | settings | Service validation; typed plugin form; hardware checks where applicable |
| `loudness.set` | enabled, compensation, equalization | Service validation; typed plugin form; hardware checks where applicable |
| `app.pin.set` | target, pinned | Service validation; typed plugin form; hardware checks where applicable |
| `app.ignore.set` | target, ignored | Service validation; typed plugin form; hardware checks where applicable |
| `shortcut.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `shortcut.set` | action, keyCode, modifiers | Service validation; typed plugin form; hardware checks where applicable |
| `shortcut.clear` | action | Service validation; typed plugin form; hardware checks where applicable |
| `settings.reset` | None | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.search` | query, limit | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.get` | profileId | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.device.select` | target, profileId | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.device.clear` | target | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.device.setEnabled` | target, enabled | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.preamp.set` | enabled | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.favorite.set` | profileId, favorite | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.import` | name, text | Service validation; typed plugin form; hardware checks where applicable |
| `autoeq.deleteImported` | profileId | Service validation; typed plugin form; hardware checks where applicable |
| `bluetooth.list` | None | Service validation; typed plugin form; hardware checks where applicable |
| `bluetooth.connect` | bluetoothId | Service validation; typed plugin form; hardware checks where applicable |
| `update.status` | None | Service validation; typed plugin form; hardware checks where applicable |
| `update.getPreferences` | None | Service validation; typed plugin form; hardware checks where applicable |
| `update.setPreferences` | automaticallyChecks, automaticallyDownloads | Service validation; typed plugin form; hardware checks where applicable |
| `update.check` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.popup.show` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.popup.hide` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.popup.toggle` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.settings.open` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.eq.open` | target | Service validation; typed plugin form; hardware checks where applicable |
| `ui.deviceInspector.open` | target | Service validation; typed plugin form; hardware checks where applicable |
| `ui.editMode.set` | enabled | Service validation; typed plugin form; hardware checks where applicable |
| `ui.deviceTab.set` | tab | Service validation; typed plugin form; hardware checks where applicable |
| `device.uid.copy` | target | Service validation; typed plugin form; hardware checks where applicable |
| `ui.permissionSettings.open` | None | Service validation; typed plugin form; hardware checks where applicable |
| `ui.help.open` | None | Service validation; typed plugin form; hardware checks where applicable |

The plugin exposes all methods through FineTune Command and supplies dedicated audio actions. Permission prompts and update installation remain normal operating-system/app UI flows. Input device inspector UI is unavailable because FineTune has no such panel; device information is still queryable.

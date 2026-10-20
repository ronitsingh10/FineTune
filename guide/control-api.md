# External control API v1

FineTune can provide bidirectional control to local controllers (for example,
Stream Deck or Launchpad integrations). Enable **Settings → General → External
controller access**. It is off by default and runs only while FineTune runs.
Existing URL actions are unchanged.

## Security and connection

Connect an AF_UNIX stream to:

```
$HOME/Library/Application Support/FineTune/Control/control.sock
```

Here HOME means the current user's home directory, not an environment-variable
override. There is no TCP/WebSocket port, authentication token, helper, or daemon.
**Every process running as your user is trusted to read and control FineTune.**
The Control directory is owned by that user and mode 0700; the socket is 0600.
FineTune rejects symlinks, foreign-owned API directories/files, and peers whose
credentials cannot be verified as the same effective UID.
Application Support must belong to your user. Its canonical ancestors must belong
to root or your user, and neither they nor the FineTune parent may be
group/world-writable. FineTune never repairs parent permissions. After binding it
verifies that the absolute socket and the validated directory identify the same
inode; failed namespace verification cleans up the socket it actually created.

A nonblocking exclusive lock on `Control/server.lock` prevents multiple listeners.
FineTune never removes the lock file. With the lock held, it removes a stale socket,
but refuses other file types. Disabling access or quitting closes connections,
cancels observation and removes only the socket it created. Re-enabling generates
a new session ID. Startup failures appear beside the setting and in Console
(category `ControlAPI`).

## Framing and lifecycle

Each frame is a UTF-8 JSON object terminated by LF. CRLF is accepted. Never send
pretty-printed JSON, empty lines, invalid UTF-8, or malformed envelopes. These close
the connection. Maximum payload is 1,048,576 bytes excluding LF. FineTune supports
eight clients, partial reads/writes, and disconnects clients that exceed eight
queued outbound frames or 4 MiB buffered output. A partial inbound frame, or
buffered output without write progress, times out after ten seconds. Oversized or
unencodable snapshots are never truncated: the affected client disconnects.

The server speaks first:

```json
{"type":"hello","protocol":"finetune-control","version":1,"appVersion":"1.9.0","sessionId":"example","capabilities":["getState","subscribe","setAppVolume","setAppMute","setAppRouting","setDefaultOutput","setPreferredInput"]}
```

Check protocol/version before sending requests. Use the hello's sessionId on every
request. Each request needs type, a nonempty string id (at most 128 UTF-8 bytes,
unique among requests still awaiting a response on that connection), sessionId,
method and an object params. Completed IDs are not retained and can be reused;
connection-unique IDs (for example, a counter) are recommended. Additional
fields are ignored. Requests are processed serially and responses remain ordered.

```json
{"type":"request","id":"1","sessionId":"example","method":"getState","params":{}}
{"type":"response","id":"1","result":{"sessionId":"example","revision":0,"state":{}}}
{"type":"request","id":"2","sessionId":"example","method":"subscribe","params":{}}
{"type":"response","id":"2","result":{"sessionId":"example","revision":0,"state":{}}}
{"type":"event","event":"stateChanged","sessionId":"example","revision":1,"state":{}}
```

`state: {}` above stands for the **complete** state described below. Both getState
and subscribe flush pending changes before returning. Subscribe registers and
returns its snapshot without a gap; its response precedes subsequent events.
Repeated subscribe returns a fresh snapshot, not a second subscription. To
unsubscribe, close the connection.

Revisions start at zero per listener session and increase once per distinct
published snapshot (up to 2^53−1). Identical snapshots do not increment them.
Changes are coalesced in a fixed 40 ms window; every event is a full snapshot.
Intermediate changes can be coalesced, but queued events are FIFO and never silently
dropped. Reconnect and resubscribe after a disconnect, discarding the old session
and state. Do not replay commands across reconnects or automatically launch FineTune.

## State

All keys are present; nullable values are explicit JSON nulls.

```json
{
  "apps": [{
    "appId": "com.example.Player", "pids": [1234], "name": "Player", "active": true,
    "volume": 0.5, "boost": 1, "muted": false,
    "routing": {
      "requested": {"mode": "single", "deviceUID": "output-uid"},
      "appliedDeviceUIDs": ["output-uid"], "status": "applied", "error": null
    }
  }],
  "devices": [{
    "uid": "output-uid", "name": "Speakers", "direction": "output", "isDefault": true,
    "volume": 0.75, "muted": false, "volumeSource": "hardware",
    "capabilities": {"volumeReadable": true, "muteReadable": true, "selectable": true}
  }],
  "defaultOutput": "output-uid", "defaultInput": null,
  "inputPolicy": {"lockEnabled": true, "preferredDeviceUID": null, "lockedDeviceUID": null},
  "permission": {"audioCapture": "authorized", "source": "preflight"}
}
```

- Apps are the engine's active audio-process rows, sorted by appId then PID. No
  inactive persisted apps or meters. Active means present in the audio-process
  list, **not proven audible**. Each pids array contains exactly the responsible
  PID of that row. Duplicate appIds are legal and must not be collapsed.
- appId is the exact, case-sensitive persistence identifier: bundle ID, or
  `name:<name>` if absent. Persist appId, not PID; resolve the current PID from
  each snapshot before writing.
- volume is managed linear gain 0…1, not slider position or app-internal volume.
  boost is a separate read-only multiplier.
- Requested routing is `{"mode":"followDefault"}`, `{"mode":"single","deviceUID":"uid"}`,
  or `{"mode":"multi","deviceUIDs":["sorted","uids"]}`.
- appliedDeviceUIDs is the sorted current tap configuration (null if unknown).
  Applied means engine/tap configuration, **not verified sound**. Status is
  unavailable, pending, applied or failed. Error is null or
  `{"code":"routingFailed","message":"Unable to configure audio routing"}` and
  persists until the next routing attempt. Superseded completions cannot replace
  a newer attempt's status.
- Devices are connected devices sorted by direction then UID. Key rows by
  `(uid,direction)`; duplex devices have separate input/output rows. Defaults
  report monitored system UIDs or null, not optimistic command targets.
- Device volume/mute are cached values or null if unsupported/unreadable.
  volumeSource is hardware, ddc, software or null; input readback uses hardware.
  Hardware cached values can be optimistic immediately after writes. Capabilities
  describe readback/selectability, not additional API writes.
- Audio capture permission is unknown, authorized or denied. Source is preflight,
  or assumed in builds without ENABLE_TCC_SPI.

## Commands

```json
{"type":"request","id":"3","sessionId":"example","method":"setAppVolume","params":{"appId":"com.example.Player","pid":1234,"volume":0.5}}
{"type":"request","id":"4","sessionId":"example","method":"setAppMute","params":{"appId":"com.example.Player","pid":1234,"muted":true}}
{"type":"request","id":"5","sessionId":"example","method":"setAppRouting","params":{"appId":"com.example.Player","pid":1234,"routing":{"mode":"followDefault"}}}
{"type":"request","id":"6","sessionId":"example","method":"setAppRouting","params":{"appId":"com.example.Player","pid":1234,"routing":{"mode":"single","deviceUID":"output-uid"}}}
{"type":"request","id":"7","sessionId":"example","method":"setDefaultOutput","params":{"deviceUID":"output-uid"}}
{"type":"request","id":"8","sessionId":"example","method":"setPreferredInput","params":{"deviceUID":"input-uid"}}
{"type":"response","id":"3","result":{"accepted":true}}
{"type":"response","id":"4","error":{"code":"invalidParams","message":"muted must be a boolean"}}
```

PID is optional, but must be a positive integer when present. Without PID,
multiple matching rows return ambiguousApp; no match returns appNotFound.
A supplied PID that no longer matches appId returns staleApp. No fuzzy name
matching, inactive-app writes, or launch-on-demand. Values are strictly typed;
gain must be finite and within 0…1; IDs must be nonempty; device UIDs must be
connected and have the requested direction.

App writes require authorized audio capture and never prompt. Device selection
does not require it. Routing writes reject multi mode and apps currently in multi
mode; volume and mute still work for those apps.

**Accepted does not mean applied.** Reconcile against getState or subscription
state. Synchronous device-selection failure returns commandFailed; asynchronous
routing failures appear in routing state. A command response is queued before its
resulting events on that connection. Preferred input follows FineTune's existing
preference/lock path without changing the lock setting. Priority and hot-plug
policies can subsequently change defaults.

Error codes: unknownMethod, staleSession, invalidParams, appNotFound, ambiguousApp,
staleApp, deviceNotFound, unsupportedRouting, permissionDenied, commandFailed,
internalError. Messages are for people; match codes, not messages. Invalid IDs,
duplicate in-flight IDs, malformed envelopes and invalid framing close the connection.

No toggle/step/batch commands, device-volume writes, EQ/boost editing, reset,
audio transport/meters, Bluetooth control, generic RPC or network access in v1.

## Troubleshooting

- No socket: enable the setting and keep FineTune running. Check any failure shown
  beside the toggle. Do not change directory/socket permissions to share access.
- Already locked: another FineTune instance owns the listener. Quit that instance;
  never remove server.lock while a listener runs.
- Unsafe path: inspect ownership and symlinks in FineTune/Control. FineTune fails
  closed rather than deleting an unrelated file or repairing a parent directory.
- permissionDenied: grant FineTune Screen & System Audio Recording access in
  System Settings. A different signing identity may require a fresh grant.
- Disconnect: discard applied-state confidence, reconnect with backoff, read the
  new hello and subscribe again. Never retry old commands automatically.
- Controller faders: coalesce writes to at most 25 Hz per target, use absolute
  gain/mute values, and show authoritative snapshot state rather than local guesses.

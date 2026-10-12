# Automation API (proposal implementation)

FineTune automation uses a versioned, current-user local interface. API v1 requests carry `apiVersion`, `id`, `method`, and `params`. Responses repeat the ID and contain exactly one `result` or `error`. Request IDs must be nonempty and at most 128 UTF-8 bytes. See `automation-fixtures/v1.json` for complete envelopes.

App targets use `target.appId` (FineTune's persistence ID), optionally `instanceId` for one current process. Device targets use `target.deviceUID` and `direction` (`output` or `input`). IDs remain stable across profiles; process IDs are never saved as stable identity.

Volume uses 0–100 gain percent; boost is separately 1x/2x/3x/4x. Slider steps use FineTune's nonlinear mapping and are explicitly distinguished from gain-percent steps. EQ gains are -12 through +12 dB. All numeric inputs must be finite.

`applied` means a completed control update; `stored` means persisted intent (including active apps whose audio tap is unavailable); `pending` includes an operation ID and does not promise hardware success. Errors include invalid_request, unsupported_version, unknown_method, invalid_parameter, not_found, ambiguous_target, unavailable, permission_required, conflict, busy, timeout, internal_error.

Existing URL commands retain compatibility. Their `set-volumes` range is 0–100; values up to 400 are not accepted by the current handler. Set boost independently through the new API.

Enable Settings → General → Local Automation API. Discovery is in `~/Library/Application Support/FineTune/Automation/discovery.json` (custom builds use FineTune-Automation). The socket is a private current-user Unix socket; the API has no network listener. Discovery and socket access are restricted to the same macOS user. Other processes running as that user can control FineTune when automation is enabled.

Send newline-delimited UTF-8 JSON. Frames are at most 1 MiB. The server admits at most eight clients, bounds request/output queues, and disconnects malformed or slow clients. Clients negotiate using `api.describe`, which returns typed command descriptors. See `automation-coverage.md` for operations.

`events.subscribe` responds with a snapshot and emits complete `state.snapshot` / `state.changed` events containing instanceId, revision, and state. State sections are apps, devices, routing, eq, preferences, autoeq, bluetooth, updates, presentation, operations and resolvedAppId. A restart changes instanceId. Full snapshots can safely replace a cache after a revision gap. Hardware/UI changes are observed or reconciled once per second; observed control changes are coalesced to 20 Hz maximum.

Slow routing, DDC, profile-loading, alert-volume and Bluetooth operations return pending with operationId. Poll `operation.get` for completed/failed outcome; never replay a toggle or relative step after an uncertain disconnect. Concurrent mutations of a busy async resource return busy. Queries remain available.

Mutations can include `expectedRevision`; stale values return conflict before writing. `batch.execute` accepts up to 64 structurally validated commands, returns a pending batch operation, awaits each command’s terminal result in order, and retains per-command results. It is non-atomic; unknown/failed commands stop the batch unless continueOnError is true. Nested batches and subscription commands are rejected. A full settings reset disables automation, gates new requests immediately, and drains its response before closing.

Profile imports accept bounded ParametricEQ text (250 KB), not arbitrary filesystem paths. The API has no shell or generic filesystem endpoint. Device UIDs and app persistence identifiers must come from discovery; missing targets are not silently substituted.

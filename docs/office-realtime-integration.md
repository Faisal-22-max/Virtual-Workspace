# Sprint 01 office integration

## Load the office

Use the existing Supabase client with the signed-in user's session and the project's public key. Use `auth.getUser()` to obtain the verified Auth ID, then read `users.id` with `users.auth_id = user.id`. Throughout the office protocol, `userId` refers to this app profile ID.

1. List the user's `workspace_members` rows filtered by `user_id = profile.id` and `status = 'active'`. Use the selected row's `workspace_id` and `role`.
2. Fetch `offices.select('id, workspace_id, map_config, map_version, updated_at').eq('workspace_id', workspaceId).maybeSingle()`. The row's `id` is `officeId`. A missing row means the workspace is unavailable to this session. A database error means the request failed. Handle these separately.
3. Read `office_size` and `office_template` from the existing `workspaces` row. A new office starts with `map_config = {}` and `map_version = 1`. Use the workspace template when the layout is empty. A layout is a JSON object up to 64 KiB when represented as PostgreSQL JSONB text. Sprint 01 leaves room geometry to the template and map configuration.
4. For coworker names, query active membership for the selected workspace with `select('user_id, profile:users!workspace_members_user_id_fkey(id, display_name, name)')`. Display `display_name`, then `name`, then a neutral fallback. Show profile names as plain text. Refresh the roster on rejoin and when an unknown profile appears, coalescing refreshes.

Existing workspaces receive an office in the migration. New ones receive it in the same transaction as workspace creation. Active members can read it and active admins can write its layout. There is no separate REST endpoint.

## Join and synchronize Presence

Import `officeTopic`, `isOfficePresence`, `isOfficeBroadcast` and the payload types from [lib/office-realtime.ts](../lib/office-realtime.ts). The canonical topic is `office:<lowercase workspace UUID>`. Use a fresh UUID from `crypto.randomUUID()` per live tab instance and preserve it in memory across reconnects. A full reload generates a new session. Switch workspace or sign out by removing the previous channel and clearing its local state before opening another.

```ts
const sessionId = crypto.randomUUID()
const channel = supabase.channel(officeTopic(workspaceId), {
  config: { private: true, presence: { key: sessionId }, broadcast: { self: false } },
})

channel
  .on('presence', { event: 'sync' }, () => {
    // Project each Presence meta onto the five OfficePresence fields before validation.
    reconcileOfficePresence(channel.presenceState())
  })
  .on('broadcast', { event: 'player_moved' }, ({ payload }) => receiveMovement('player_moved', payload))
  .on('broadcast', { event: 'player_stopped' }, ({ payload }) => receiveMovement('player_stopped', payload))
  .on('broadcast', { event: 'office_layout_updated' }, ({ payload }) => receiveLayoutHint(payload))

await supabase.realtime.setAuth()
channel.subscribe(status => {
  if (status === 'SUBSCRIBED') {
    // On every successful join, recheck office access and track once.
    void recheckAndTrack(channel, {
      userId: profile.id, workspaceId, officeId, sessionId, joinedAt: new Date().toISOString(),
    } satisfies OfficePresence)
  }
})
```

The example callbacks are integration points. `recheckAndTrack` rereads the office and updates the active roster, then calls `await channel.track(presence)` if still subscribed to the same office. Handle a non-`ok` tracking result as a transient failure. Register listeners before subscribing. Let the Supabase client propagate refreshed Auth tokens.

- `OfficePresence` has `userId`, `workspaceId`, `officeId`, `sessionId` and ISO UTC `joinedAt`. The SDK adds `presence_ref`; project the five declared fields explicitly. Validate the workspace, office and Presence key against local context.
- Use the latest `sync` state to reconcile sessions. Keep only valid sessions whose claimed profile is in the active roster. Group sessions by profile ID and display one avatar. Keep the current controlling session while it is present. If it leaves, choose the remaining session with the lexicographically smallest ID. Remove the avatar when the last eligible session disappears. Use `join`/`leave` deltas for diagnostics, with `sync` driving the rendered roster.
- Derive the local user's ID from Auth and the profile query. Render names from the directory. Remote profile IDs, session IDs and timestamps are client claims for display and coordination. An authorized member can still impersonate another roster entry or session in raw Realtime traffic. Never use those claims for permissions, audit attribution, moderation, or identity-sensitive actions. A verified sender contract would require a server-mediated or signed event protocol. [Supabase Presence](https://supabase.com/docs/guides/realtime/presence), [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization)

## Broadcast and layout changes

Send with `channel.send({ type: 'broadcast', event, payload })` only after subscribing and successfully tracking Presence.

| Event | Payload | Receiver behavior |
| --- | --- | --- |
| `player_moved` | `PlayerMoved` with `officeId`, `sessionId`, `x`, `y`, `direction`, `sequence` | Apply the newest position for the controlling session. |
| `player_stopped` | `PlayerStopped` with the same fields and final position | Apply the final position and stop interpolation. |
| `office_layout_updated` | `OfficeLayoutUpdated` with `officeId`, `mapVersion` | For a newer version, coalesce a refetch and apply the authorized office row. |

Movement coordinates are finite normalized fractions in `[0, 1]`, with the origin at the upper left. Directions are `up`, `down`, `left`, `right`. Call `isOfficeBroadcast` with the office ID fetched for the current workspace and the latest accepted sequence for the session. Require an eligible Presence session before applying movement. Payloads have a 512-byte UTF-8 cap in the shared validator. Sequence starts at zero and increases across both movement events for each session. Keep the sender sequence across reconnects with the same session ID. Drop duplicates, reordered events and packets for missing sessions. Broadcast has no required replay. Initialize an unseen position at a map spawn until new movement arrives.

Use `OFFICE_MOVEMENT_INTERVAL_MS` to throttle moving updates to once per 125 ms (8/s). Coalesce intermediate positions into the latest sample, skip identical samples and send a single final stop when motion ends. A stop may flush ahead of the next scheduled sample. Pause sends while disconnected and discard queued movement. Animate locally between samples. Client throttling and payload checks protect rendering and reduce load. Supabase checks topic access at authorization time and applies project quotas. Per-member movement limits, payload validation and sender binding would require a trusted relay if the product needs server enforcement.

An admin saves through `offices.update({ map_config: layout }).eq('id', officeId).eq('map_version', lastReadVersion).select('id, map_config, map_version, updated_at').maybeSingle()`. When zero rows return, refetch to distinguish a version conflict from lost access. For a successful changed version, publish `office_layout_updated` with the returned version. The event is a refresh hint that any connected member could send. Only the fetched row supplies layout or version. Refetch on reconnect and when the office tab regains focus to recover from missed hints.

## Disconnect, reconnect, and access changes

- On normal navigation, workspace switch or logout, remove the channel and clear its state. Presence removes the session when the channel leaves or Realtime detects a lost socket. Detection after abrupt network loss takes time.
- On `CHANNEL_ERROR`, `TIMED_OUT` or `CLOSED`, pause sends and clear or hide the previous roster. If office read fails for a transient reason, use bounded backoff. If the workspace or office is unavailable to the session, remove the channel and return to workspace selection. On each successful rejoin recheck membership through the office read and track again. Discard callbacks from a previous workspace.
- After membership is removed, new channel joins and office reads fail immediately. An existing channel caches Broadcast and Presence grants. A fresh JWT causes reevaluation, and expiry disconnects a channel without a new JWT. Keep the project's JWT lifetime appropriate for the product's revocation window. Honest clients can detect lost access earlier by rechecking on focus and rejoin. There is no instant eviction guarantee for already-authorized sockets. [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization)

Use private channels for all office clients. Supabase isolates a public namesake from the private channel. To block creation of public channels project-wide, turn off **Allow public access** in the target's Realtime settings during an approved rollout. This also affects the existing public `test-map-room` prototype. Confirm the setting or keep the prototype and retest public/private isolation on the target. [Realtime settings](https://supabase.com/docs/guides/realtime/settings), [Supabase channel concepts](https://github.com/supabase/supabase/blob/master/apps/docs/content/guides/realtime/concepts.mdx)

## Two-device acceptance test

Use a local or development Supabase environment with three test users, A (workspace admin), B (active member of A's workspace) and C (member only of another workspace). A script or DevTools client with the public key is sufficient.

1. Log A and B in on two devices or separate browser profiles. Select the same workspace, fetch the office and join privately. Track once. Confirm both see the same office ID and the expected names from the active roster.
2. Send movement and stop packets from A, then from B. Confirm position and stop reach the other device. Send a repeated sequence and a wrong-office packet and confirm those packets are discarded by the receiver. Record receive latency and disconnect cleanup time. For the manual local smoke, target movement receipt within 500 ms under light load.
3. Open a second tab for A. Confirm two Presence sessions and one avatar. Close one tab, then briefly drop the remaining tab's connection. Confirm expired sessions disappear and reconnect reestablishes one avatar. Switch workspace and confirm the old roster is cleared.
4. Confirm C cannot read the office or join its private topic. Also try a malformed private topic. As A, save a layout and send a refresh hint. Confirm B fetches the new version and cannot save a layout.
5. Revoke B as A. Confirm B can no longer fetch the row or join from a new socket. Observe that an already-open socket may still receive events until JWT refresh or expiry. Refresh B's token, confirm the channel loses access and verify its Presence disappears.

For the automated socket test, start a disposable Supabase project named `vw-office-fresh`, with API port 54421, under `/tmp/virtual-workspace-local-test/office-fresh.XXXXXX` (substitute the suffix generated by `mktemp -d`). Copy the local-only baseline first and then the repository migrations into that disposable project's migration directory. Run `node supabase/tests/office_realtime_test.mjs "$workdir"` from the repository. Set `VW_SUPABASE_CLI` to the CLI path if installed outside `node_modules`.

## Logging and capacity

Count join errors by status, reconnect attempts, actual sends per second and client validation drops by reason. Treat any successful cross-workspace delivery as an isolation incident and retain only event type, status, timing and a non-sensitive correlation ID. Avoid logging JWTs, API keys, names, payloads or stable customer identifiers.

Compare Realtime Reports with the target's configured limits before sizing a workspace. As reference, documented Free / Pro limits are 200 / 500 concurrent connections, 100 / 500 total messages per second, and 20 / 50 Presence messages per second. Presence calls are limited to five per client per 30 seconds. Each Broadcast delivery counts toward total throughput, so capacity depends on both concurrent movers and recipients. Treat the target project's settings as the source of truth. [Realtime limits](https://supabase.com/docs/guides/realtime/limits), [Realtime settings](https://supabase.com/docs/guides/realtime/settings)

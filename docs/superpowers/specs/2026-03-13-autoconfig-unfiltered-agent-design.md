# Auto Configurator: Unfiltered Agent Results with Client-Side Filtering

**Date:** 2026-03-13
**Status:** Draft

## Problem

The Swift agent filters TCC, notification, login item, and system extension results server-side using a truncated search term derived from the app's bundle ID. This causes valid entries to be silently missed (e.g. CrowdStrike's notification registered under `com.crowdstrike.falcon.useragent` when the app's bundle ID is `com.crowdstrike.falcon.Agent`). Users have no visibility into what was found vs. what was matched, and no way to correct false negatives.

## Solution

Move all filtering to the browser. The agent returns everything it finds; the JS categorizes results into "matched" and "unmatched" using a cascading search strategy, and the UI lets users see and override both categories.

## Architecture: Two-Phase Agent

The agent uses a persistent HTTP server (same pattern as `startBrowseServer`/`startDMGPackagerServer` which already use `parseHTTPRequest` and route by method + path) to support a two-phase flow:

### Phase 1 — Scan (on app drop)

Agent launches via `macadmin-toolbox://fetch-tcc?search={fullBundleId}&scope=full`, queries all databases **unfiltered**, and serves results via `GET /result`. Stays alive with a **5-minute idle timeout** — if no `/resolve` request arrives within 5 minutes, the agent terminates. If the user drops a second app while an agent is still running, the browser should first check if port 8765 is responding and cancel/wait before launching a new agent.

**Response shape:**
```json
{
  "search_term": "com.crowdstrike.falcon.Agent",
  "tcc_raw": [
    {"client": "/Library/CS/falcon", "service": "SystemPolicyAllFiles", "resolved_bundle_id": "com.crowdstrike.falcon.Agent"},
    {"client": "com.apple.Safari", "service": "Camera", "resolved_bundle_id": null}
  ],
  "notifications": [
    {"original_id": "com.crowdstrike.falcon.useragent"},
    {"original_id": "com.apple.Safari"},
    {"original_id": "com.microsoft.teams2"}
  ],
  "login_items": [
    {"team_id": "X9E956P446", "source_file": "com.crowdstrike.falcon.plist"}
  ],
  "system_extensions": [
    {"identifier": "com.crowdstrike.falcon.Agent", "team_id": "...", ...}
  ]
}
```

Key changes from current agent:
- **`tcc_raw`** replaces `entries`. Contains client + profile-key service name (stripped `kTCCService` prefix) + optional `resolved_bundle_id`. No full `codesign -dr` is run, but for path-based clients a lightweight `bundleID(forPath:)` call (`codesign -dv`) resolves the bundle ID so the cascade can match on it. Entries with unrecognized services (where `tccServiceToProfileKey` returns nil) are excluded.
- **`notifications`** — all rows from the notification DB `app` table.
- **`login_items`** — all plists from `/Library/LaunchDaemons` and `/Library/LaunchAgents` with resolved team IDs. **Note:** This is a shape change from the current `[String]` (team ID array) to `[{team_id, source_file}]` so the UI can display which plist each team ID came from. Codesign runs on all referenced binaries upfront (lightweight). On machines with many launch daemons this may add a second or two.
- **`system_extensions`** — all entries from `/Library/SystemExtensions/db.plist` with team IDs and categories resolved.
- **`search_term`** — the **full bundle ID** from the URL, passed through for informational purposes. The JS uses the locally-parsed Mach-O identifier (not this field) as the source of truth for cascade filtering.

### Phase 2 — Resolve (on profile generate)

Browser POSTs selected TCC clients to `POST /resolve`:

**Request:**
```json
{"clients": ["/Library/CS/falcon", "com.apple.Safari"]}
```

**Response:**
```json
{
  "entries": [
    {
      "path_or_label": "/Library/CS/falcon",
      "identifier": "com.crowdstrike.falcon.Agent",
      "code_requirement": "anchor apple generic and ...",
      "permissions": ["SystemPolicyAllFiles"]
    }
  ]
}
```

The agent runs full `codesign -dr`, resolves bundle IDs/paths, groups permissions by path, and returns the same `AgentEntry` shape used today. Clients that no longer exist on disk are silently skipped. After serving the response, the agent terminates.

**Error handling:** If codesign hangs for a client, a per-client timeout (10 seconds) ensures the resolve does not block indefinitely. Timed-out clients are skipped.

**UX:** The JS shows a progress indicator ("Resolving permissions...") while waiting for `/resolve` to respond.

## Client-Side Filtering: Cascading Search

The JS uses the **locally-parsed Mach-O identifier** (the `ident` variable from `autoconfigParseMachOSigning`) as the source of truth for filtering — not the `search_term` field from the agent response.

It applies a cascading search strategy to categorize each raw entry as "matched" or "unmatched":

1. **Full bundle ID** — e.g. `com.crowdstrike.falcon.Agent` (contains, case-insensitive)
2. **First 3 parts + dot** — e.g. `com.crowdstrike.falcon.` (contains, case-insensitive)
3. **First 2 parts + dot** — e.g. `com.crowdstrike.` (contains, case-insensitive)

The cascade stops at the first level that produces at least one match. Everything that didn't match at that level goes into "unmatched."

This prevents `com.microsoft.wdav` from matching all `com.microsoft.*` entries — it first tries the full ID, then `com.microsoft.wdav.` which catches helpers like `com.microsoft.wdav.epsext`.

**For TCC entries:** The cascade matches against both `client` and `resolved_bundle_id` (if present). This ensures path-based TCC clients like `/Library/CS/falcon` can match via their resolved bundle ID.

**Edge cases:**
- **Single-part bundle IDs** (e.g. `falcon`): All three cascade levels are identical — degenerates to a single contains check. This is correct.
- **Two-part bundle IDs** (e.g. `com.crowdstrike`): Levels 2 and 3 are identical. Harmless.
- **No matches at any level:** All entries go into "unmatched." The matched section is empty and the "Also found" section is expanded by default so the user can manually select.
- **Stop-at-first behavior:** If level 1 (exact match) finds just one entry, levels 2 and 3 are not tried. Related helpers end up in "unmatched." This is intentional — the user sees them in the collapsible section and can check them manually.

## UI Changes

Each category (TCC, Notifications, Login Items, System Extensions) gets a card with two sections:

### Matched section (top, expanded)
- Entries that passed the cascading search filter
- Each entry has a checkbox, **checked by default**
- Shows relevant details (client + service for TCC, identifier for notifications, etc.)

### "Also found on this Mac" section (collapsible, collapsed by default)
- All entries that didn't match
- Each entry has a checkbox, **unchecked by default**
- User can expand and check any entry to include it
- If there are no matched entries, this section is **expanded by default**

### Card header
Shows counts: e.g. "Notifications (2 matched, 14 other)"

## Profile Generation Flow

1. User reviews and adjusts checkboxes across all categories
2. Clicks "Download profile(s)"
3. JS shows "Resolving permissions..." progress indicator
4. JS collects all checked TCC clients → POSTs to `POST /resolve` → waits for resolved entries
5. JS uses checked notifications, login items, system extensions directly (no second call needed)
6. Profile is generated with all resolved/selected data

## Swift Agent Changes

### New/modified functions:
- `fetchTCCRaw()` → queries `SELECT client, service FROM access;`, returns all `(client, profileKey, resolvedBundleId?)` tuples where `tccServiceToProfileKey` returns non-nil. Runs lightweight `bundleID(forPath:)` on path-based clients only. No full codesign.
- `fetchAllNotifications()` → queries notification DB, returns all identifiers. No search filtering.
- `fetchAllLoginItems()` → scans LaunchDaemons/LaunchAgents, resolves team IDs for all plists. No search filtering.
- `fetchAllSystemExtensions()` → reads all system extensions from db.plist with full metadata. No search filtering.
- `fetchAll()` → calls the above, returns `AgentScanResponse`.
- `resolveTCCClients(clients:)` → takes specific client strings, runs full codesign/path resolution (with 10s per-client timeout), returns `[AgentEntry]`.

### New structs:
- `AgentTCCRawEntry: Encodable` — `{client: String, service: String, resolved_bundle_id: String?}`
- `AgentLoginItem: Encodable` — `{team_id: String, source_file: String}` (shape change from current `[String]`)
- `AgentScanResponse: Encodable` — replaces `AgentResponse` for the scan phase

### Server changes:
- Replace `serveResult` with a multi-route HTTP handler (following the `startBrowseServer`/`parseHTTPRequest` pattern already used elsewhere in the codebase). Routes: `GET /result` (phase 1 scan data), `POST /resolve` (phase 2 TCC resolution).
- 5-minute idle timeout — agent terminates if no requests arrive.
- After serving `/resolve` response, agent terminates.

### Removed:
- `fetchTCC(searchTerm:)` — replaced by `fetchTCCRaw()` + `resolveTCCClients(clients:)`
- `fetchNotifications(searchTerm:)` — replaced by `fetchAllNotifications()`
- `fetchLoginItems(searchTerm:)` — replaced by `fetchAllLoginItems()`
- `fetchSystemExtensions(searchTerm:)` — replaced by `fetchAllSystemExtensions()`
- Debug NSLog lines added during investigation

### Kept as-is:
- `fetchCodeRequirementOnly(searchTerm:)` — the "Add entry" drop zone flow is a separate UX (user drops a specific binary to get its code requirement) and doesn't benefit from the unfiltered scan approach. It remains a one-shot agent launch.

## JS Changes (`auto_configurator.html`)

### New:
- `autoconfigCascadeFilter(items, bundleId, keyFn)` — implements the 3-level cascading search, returns `{matched: [], unmatched: []}`
- `autoconfigRenderScanResults(data)` — renders the category cards with checkboxes and collapsible sections
- Updated `autoconfigGenerate()` — collects checked items, POSTs TCC clients to `/resolve`, shows progress indicator, builds profile

### Modified:
- `autoconfigFetchFromMac()` — passes full bundle ID as search term (no truncation)
- `startPollForFull()` — on receiving scan results, calls `autoconfigRenderScanResults` instead of `autoconfigMergeAgentEntries`
- `autoconfigMergeAgentEntries()` — updated or replaced to work with new response shape

### Removed:
- Search term truncation logic (lines 459-461, 494-496, 705-707)
- `autoconfigFindMatchingEntry()` — no longer needed

## Impact on "Add Entry" Flow

The "Add entry" drop zone flow (`fetchCodeRequirementOnly`) stays as-is. It's a separate one-shot agent launch that uses `scope=code_requirement` to fetch only TCC data for a single app. It doesn't need the unfiltered scan UI.

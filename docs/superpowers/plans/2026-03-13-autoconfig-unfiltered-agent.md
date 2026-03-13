# Auto Configurator: Unfiltered Agent Results Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all TCC/notification/login-item/system-extension filtering from the Swift agent to the browser, giving users visibility into all found results and the ability to override automatic matching.

**Architecture:** Two-phase agent (scan → resolve) with persistent HTTP server. Phase 1 returns all raw data unfiltered. JS applies cascading bundle-ID matching to categorize entries as matched/unmatched. User reviews checkboxes. Phase 2 resolves codesign only for selected TCC entries on profile generation.

**Tech Stack:** Swift (macOS agent), vanilla JS (browser template), NWListener HTTP server

**Spec:** `docs/superpowers/specs/2026-03-13-autoconfig-unfiltered-agent-design.md`

---

## Chunk 1: Swift Agent — New Structs and Unfiltered Fetch Functions

### Task 1: Add new structs and replace filtered fetch functions

**Files:**
- Modify: `agent/Sources/MacAdminToolbox/main.swift:108-134` (structs section)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:176-206` (fetchNotifications)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:231-255` (fetchLoginItems)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:259-322` (fetchSystemExtensions)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:347-391` (fetchTCC)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:393-401` (fetchAll / fetchCodeRequirementOnly)

- [ ] **Step 1: Add new structs after existing ones (line ~134)**

Add these structs right after the existing `AgentResponse` struct:

```swift
struct AgentTCCRawEntry: Encodable {
    let client: String
    let service: String
    let resolved_bundle_id: String?
}

struct AgentLoginItem: Encodable {
    let team_id: String
    let source_file: String
}

struct AgentScanResponse: Encodable {
    let search_term: String?
    let tcc_raw: [AgentTCCRawEntry]
    let notifications: [AgentNotification]
    let login_items: [AgentLoginItem]
    let system_extensions: [AgentSystemExtension]
}
```

- [ ] **Step 2: Replace `fetchNotifications(searchTerm:)` with `fetchAllNotifications()`**

Replace the entire function at lines 176-206 with:

```swift
func fetchAllNotifications() -> [AgentNotification] {
    guard let dbPath = notificationDBPath(), FileManager.default.fileExists(atPath: dbPath),
          case .success(let rows) = runSQLiteSingleColumn(query: "SELECT identifier FROM app;", dbPath: dbPath) else {
        return []
    }
    return rows.compactMap { row in
        let ident = row.trimmingCharacters(in: .whitespaces)
        return ident.isEmpty ? nil : AgentNotification(original_id: ident)
    }
}
```

This removes search filtering and the debug NSLog lines. Returns all notification identifiers from the DB.

- [ ] **Step 3: Replace `fetchLoginItems(searchTerm:)` with `fetchAllLoginItems()`**

Replace the entire function at lines 231-255 with:

```swift
func fetchAllLoginItems() -> [AgentLoginItem] {
    let dirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents"]
    var results: [AgentLoginItem] = []
    let fm = FileManager.default
    for dir in dirs {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for file in files where file.lowercased().hasSuffix(".plist") {
            let plistPath = (dir as NSString).appendingPathComponent(file)
            guard let plistData = fm.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { continue }
            var foundTeamIDs: Set<String> = []
            if let args = plist["ProgramArguments"] as? [String] {
                for arg in args where fm.fileExists(atPath: arg) {
                    if let tid = teamID(forPath: arg) { foundTeamIDs.insert(tid) }
                }
            }
            if foundTeamIDs.isEmpty, let program = plist["Program"] as? String, fm.fileExists(atPath: program), let tid = teamID(forPath: program) {
                foundTeamIDs.insert(tid)
            }
            for tid in foundTeamIDs.sorted() {
                results.append(AgentLoginItem(team_id: tid, source_file: file))
            }
        }
    }
    return results
}
```

Key change: No search filtering. Returns all plists with their team IDs. Shape changes from `[String]` to `[AgentLoginItem]` with `source_file` for display.

- [ ] **Step 4: Replace `fetchSystemExtensions(searchTerm:)` with `fetchAllSystemExtensions()`**

Replace the entire function at lines 259-322 with the same logic but removing the search filter. Remove these two lines from the top:

```swift
// REMOVE:
var searchNorm = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
if searchNorm.hasSuffix(".") { searchNorm.removeLast() }
guard !searchNorm.isEmpty else { return [] }
```

And remove this filter line inside the for loop:

```swift
// REMOVE:
if !ident.lowercased().contains(searchNorm) { continue }
```

The function signature becomes `func fetchAllSystemExtensions() -> [AgentSystemExtension]`. Everything else (codesign for team ID, filter requirement extraction, etc.) stays identical.

- [ ] **Step 5: Replace `fetchTCC(searchTerm:)` with `fetchTCCRaw()`**

Replace the entire function at lines 347-391 with:

```swift
func fetchTCCRaw() -> [AgentTCCRawEntry] {
    guard case .success(let lines) = runSQLite(query: "SELECT client, service FROM access;", dbPath: tccDBPath) else {
        return []
    }
    var results: [AgentTCCRawEntry] = []
    var seen: Set<String> = []
    for line in lines {
        let parts = line.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        let client = parts[0]
        let service = parts[1]
        guard let profileKey = tccServiceToProfileKey(service), !profileKey.isEmpty else { continue }
        let dedupeKey = "\(client)\0\(profileKey)"
        guard !seen.contains(dedupeKey) else { continue }
        seen.insert(dedupeKey)
        let resolvedBID: String?
        if client.hasPrefix("/") {
            resolvedBID = bundleID(forPath: client)
        } else {
            resolvedBID = client
        }
        results.append(AgentTCCRawEntry(client: client, service: profileKey, resolved_bundle_id: resolvedBID))
    }
    return results
}
```

Key changes: No search filtering. No full codesign (`-dr`). For path-based clients, runs lightweight `bundleID(forPath:)` (`codesign -dv`) to resolve bundle ID for cascade matching. Returns raw entries with profile-key service names (not `kTCCService*`). Deduplicates by client+service.

- [ ] **Step 6: Add `resolveTCCClients(clients:)` function**

Add after `fetchTCCRaw()`:

```swift
func resolveTCCClients(clients: [String]) -> [AgentEntry] {
    guard case .success(let lines) = runSQLite(query: "SELECT client, service FROM access;", dbPath: tccDBPath) else {
        return []
    }
    let clientSet = Set(clients)
    var pathToServices: [String: Set<String>] = [:]
    for line in lines {
        let parts = line.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        let client = parts[0]
        let service = parts[1]
        guard clientSet.contains(client) else { continue }
        let isPath = client.hasPrefix("/")
        let path: String
        if isPath {
            path = client
        } else {
            guard let p = pathForBundleID(client) else { continue }
            path = p
        }
        guard let profileKey = tccServiceToProfileKey(service), !profileKey.isEmpty else { continue }
        pathToServices[path, default: []].insert(profileKey)
    }
    return pathToServices.compactMap { path, perms in
        // 10-second timeout per client: run codesign in a subprocess with deadline
        let semaphore = DispatchSemaphore(value: 0)
        var cr: (identifier: String, requirement: String)?
        DispatchQueue.global().async {
            cr = codeRequirementOrNil(forPath: path)
            semaphore.signal()
        }
        let timeout = semaphore.wait(timeout: .now() + 10)
        guard timeout == .success, let resolved = cr, !resolved.identifier.isEmpty, !resolved.requirement.isEmpty else { return nil }
        return AgentEntry(
            path_or_label: path,
            identifier: resolved.identifier,
            code_requirement: resolved.requirement,
            permissions: Array(perms).sorted()
        )
    }
}
```

This is the existing `fetchTCC` logic but filtered to only the user-selected clients. Runs full `codesign -dr` only on selected items. Each client has a 10-second timeout — if codesign hangs, the entry is skipped. The duplicate `codeRequirementOrNil` guard call is removed; the `compactMap` handles the nil case.

- [ ] **Step 7: Update `fetchAll()` to return `AgentScanResponse`**

Replace `fetchAll(searchTerm:)` at lines 393-405 with:

```swift
func fetchAllScan(searchTerm: String) -> AgentScanResponse {
    let tccRaw = fetchTCCRaw()
    let notifications = fetchAllNotifications()
    let loginItems = fetchAllLoginItems()
    let systemExtensions = fetchAllSystemExtensions()
    return AgentScanResponse(
        search_term: searchTerm,
        tcc_raw: tccRaw,
        notifications: notifications,
        login_items: loginItems,
        system_extensions: systemExtensions
    )
}
```

Keep `fetchCodeRequirementOnly(searchTerm:)` as-is — it's used by the "Add entry" drop zone flow which remains unchanged. **Important:** `fetchCodeRequirementOnly` calls `fetchTCC(searchTerm:)`, so `fetchTCC` must also be kept (it is NOT deleted in Task 2 Step 3).

- [ ] **Step 8: Build to verify compilation**

Run: `cd agent && swift build 2>&1 | tail -20`

Expected: Build will fail because `fetchAll` callers still reference old function. That's fine — we fix the callers in Task 2. Just verify the new structs and functions have no syntax errors (look for errors in the new code, ignore "cannot find 'fetchAll'" errors).

- [ ] **Step 9: Commit**

```bash
git add agent/Sources/MacAdminToolbox/main.swift
git commit -m "feat(agent): add unfiltered fetch functions and scan response structs

Replace filtered fetch functions with unfiltered variants that return
all entries from TCC, notification, login item, and system extension
databases. Add AgentScanResponse, AgentTCCRawEntry, AgentLoginItem
structs for the new response shape. Add resolveTCCClients() for
phase-2 codesign resolution of user-selected TCC entries."
```

---

### Task 2: Replace one-shot server with persistent multi-route handler

**Files:**
- Modify: `agent/Sources/MacAdminToolbox/main.swift:497-547` (serveResult function)
- Modify: `agent/Sources/MacAdminToolbox/main.swift:662-687` (fetch-tcc URL handler)

- [ ] **Step 1: Add the persistent scan server function**

Add a new function `startScanServer` that replaces the one-shot `serveResult` for the fetch-tcc flow. This follows the same pattern as `startBrowseServer` (line 765) — uses `parseHTTPRequest`, routes by method+path, stays alive.

Add after the existing `serveResult` function (keep `serveResult` — it's still used by other flows):

```swift
func startScanServer(scanData: Data) {
    let queue = DispatchQueue(label: "com.macadmin.scanServer")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else { return }

    var idleTimer: DispatchWorkItem?
    func resetIdleTimer() {
        idleTimer?.cancel()
        let item = DispatchWorkItem {
            listener.cancel()
            NSApp.terminate(nil)
        }
        idleTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: item)
    }
    resetIdleTimer()

    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data = data, let request = parseHTTPRequest(data) else {
                connection.cancel()
                return
            }
            if request.method == "OPTIONS" {
                let resp = corsPreflightResponse()
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if request.path == "/result" && request.method == "GET" {
                resetIdleTimer()
                let resp = jsonResponseFromData(scanData)
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if request.path == "/resolve" && request.method == "POST" {
                let clients: [String]
                if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                   let c = json["clients"] as? [String] {
                    clients = c
                } else {
                    let resp = jsonResponse(["error": "Invalid request body"], status: "400 Bad Request")
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let entries = resolveTCCClients(clients: clients)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let responseObj = ["entries": entries]
                    guard let responseData = try? encoder.encode(responseObj) else {
                        let resp = jsonResponse(["error": "Encoding failed"], status: "500 Internal Server Error")
                        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let resp = jsonResponseFromData(responseData)
                    connection.send(content: resp, completion: .contentProcessed { _ in
                        connection.cancel()
                        listener.cancel()
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    })
                }
                return
            }
            let resp = jsonResponse(["error": "Not found"], status: "404 Not Found")
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    listener.start(queue: queue)
}
```

Note: `resolveTCCClients` runs on a background queue to avoid blocking the server for long codesign operations.

- [ ] **Step 2: Update the `fetch-tcc` URL handler to use the new flow**

Replace the `DispatchQueue.global` block inside the `host == "fetch-tcc"` handler (lines 678-686) with:

```swift
DispatchQueue.global(qos: .userInitiated).async {
    if let permissionError = checkTCCPermission() {
        let encoder = JSONEncoder()
        let errorResponse = AgentErrorResponse(error: permissionError, permission_required: true)
        guard let data = try? encoder.encode(errorResponse) else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async {
            showPermissionErrorWindow(message: permissionError)
            serveResult(jsonData: data, terminateAfter: false)
        }
        return
    }
    if scopeFull {
        let response = fetchAllScan(searchTerm: search)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response) else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async {
            startScanServer(scanData: data)
        }
    } else {
        let response = fetchCodeRequirementOnly(searchTerm: search)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response) else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async {
            serveResult(jsonData: data)
        }
    }
}
```

The `scopeFull` branch now uses `fetchAllScan` + `startScanServer` (persistent, two-phase). The `!scopeFull` branch (add-entry flow) still uses the old `fetchCodeRequirementOnly` + one-shot `serveResult`.

- [ ] **Step 3: Remove old filtered fetch functions that are now dead code**

Delete these functions which are replaced by the new unfiltered variants:
- `fetchNotifications(searchTerm:)` / the old debug-logged version (was at ~176-206)
- `fetchLoginItems(searchTerm:)` (was at ~231-255)
- `fetchSystemExtensions(searchTerm:)` (was at ~259-322)
- `fetchAll(searchTerm:)` (was at ~393-405)

**Keep these** — still used by the "Add entry" flow (`fetchCodeRequirementOnly`):
- `fetchTCC(searchTerm:)` — called by `fetchCodeRequirementOnly`
- `AgentResponse` struct — returned by `fetchCodeRequirementOnly`
- `fetchCodeRequirementOnly(searchTerm:)` — used by add-entry drop zone

- [ ] **Step 4: Build and verify**

Run: `cd agent && swift build 2>&1 | tail -20`

Expected: Successful build with no errors. If there are errors about missing references, fix them.

- [ ] **Step 5: Commit**

```bash
git add agent/Sources/MacAdminToolbox/main.swift
git commit -m "feat(agent): persistent two-phase scan server for fetch-tcc

Replace one-shot serveResult with startScanServer for the full scan
flow. GET /result returns unfiltered scan data, POST /resolve runs
codesign on user-selected TCC clients. 5-minute idle timeout.
The add-entry flow still uses one-shot serveResult."
```

---

## Chunk 2: JavaScript — Cascading Filter, Scan Results UI, and Profile Generation

### Task 3: Update JS to pass full bundle ID and add cascading filter function

**Files:**
- Modify: `app/templates/tools/auto_configurator.html:409-412` (state variables)
- Modify: `app/templates/tools/auto_configurator.html:455-472` (main drop handler — search term)
- Modify: `app/templates/tools/auto_configurator.html:491-507` (buffer drop handler — search term)

- [ ] **Step 1: Add scan result state variables and cascading filter function**

After the existing state variables at line ~412 (`var autoconfigNotifications = [];`), add:

```javascript
var autoconfigScanData = null;  // raw scan response from agent

function autoconfigCascadeFilter(items, bundleId, keyFn) {
    if (!bundleId || !items || !items.length) return { matched: [], unmatched: items || [] };
    var parts = bundleId.split('.');
    var levels = [bundleId.toLowerCase()];
    if (parts.length >= 3) levels.push(parts.slice(0, 3).join('.').toLowerCase() + '.');
    if (parts.length >= 2) levels.push(parts.slice(0, 2).join('.').toLowerCase() + '.');
    for (var li = 0; li < levels.length; li++) {
        var term = levels[li];
        var matched = [], unmatched = [];
        for (var i = 0; i < items.length; i++) {
            var key = (keyFn(items[i]) || '').toLowerCase();
            if (key.indexOf(term) !== -1) {
                matched.push(items[i]);
            } else {
                unmatched.push(items[i]);
            }
        }
        if (matched.length > 0) return { matched: matched, unmatched: unmatched };
    }
    return { matched: [], unmatched: items };
}
```

The `keyFn` extracts the string to match against from each item (e.g., `original_id` for notifications, `client` or `resolved_bundle_id` for TCC).

- [ ] **Step 2: Update main drop handler to pass full bundle ID (no truncation)**

In the main drop handler around lines 455-466, replace the search term construction:

```javascript
// REPLACE lines 458-465:
        var ident = result.identifier || '';
        var teamId = result.teamId || null;
        var searchTerm = ident;
        autoconfigSearchTerm = searchTerm;
```

Remove the `parts`/`truncated` logic entirely. The search term is now the full bundle ID.

- [ ] **Step 3: Update buffer drop handler the same way**

In `autoconfigAnalyzeFromBuffer` around lines 491-500, apply the same change:

```javascript
// REPLACE lines 491-499:
      var ident = result.identifier || '';
      var searchTerm = ident;
      autoconfigSearchTerm = searchTerm;
```

Remove the `parts`/`truncated` logic.

- [ ] **Step 4: Commit**

```bash
git add app/templates/tools/auto_configurator.html
git commit -m "feat(autoconfig): add cascading filter and pass full bundle ID

Add autoconfigCascadeFilter() that tries full ID, then 3-part prefix,
then 2-part prefix. Remove search term truncation from drop handlers."
```

---

### Task 4: Add scan results UI rendering

**Files:**
- Modify: `app/templates/tools/auto_configurator.html:86-98` (HTML — replace permission entries card)
- Modify: `app/templates/tools/auto_configurator.html` (JS — add render function)

- [ ] **Step 1: Replace the "Permission entries" card HTML**

Replace the card at lines 86-98 with cards for each category:

```html
      <div id="autoconfig-after-drop" style="display:none;">

      <!-- TCC Permissions -->
      <div class="card" id="autoconfig-tcc-card" style="display:none;">
        <div class="card-title" id="autoconfig-tcc-title">TCC Permissions</div>
        <div class="item-list" id="autoconfig-tcc-matched"></div>
        <div class="card-collapsible" id="autoconfig-tcc-other-section" style="display:none;">
          <button type="button" class="card-title card-collapse-trigger" onclick="autoconfigToggleScanSection('tcc')" style="font-size:12px;margin-top:8px;">
            <span class="card-collapse-icon" id="autoconfig-tcc-other-icon">▶</span>
            <span id="autoconfig-tcc-other-label">Also found on this Mac</span>
          </button>
          <div id="autoconfig-tcc-other-body" style="display:none;">
            <div class="item-list" id="autoconfig-tcc-unmatched"></div>
          </div>
        </div>
      </div>

      <!-- Notifications -->
      <div class="card" id="autoconfig-notif-card" style="display:none;">
        <div class="card-title" id="autoconfig-notif-title">Notifications</div>
        <div class="item-list" id="autoconfig-notif-matched"></div>
        <div class="card-collapsible" id="autoconfig-notif-other-section" style="display:none;">
          <button type="button" class="card-title card-collapse-trigger" onclick="autoconfigToggleScanSection('notif')" style="font-size:12px;margin-top:8px;">
            <span class="card-collapse-icon" id="autoconfig-notif-other-icon">▶</span>
            <span id="autoconfig-notif-other-label">Also found on this Mac</span>
          </button>
          <div id="autoconfig-notif-other-body" style="display:none;">
            <div class="item-list" id="autoconfig-notif-unmatched"></div>
          </div>
        </div>
      </div>

      <!-- Login Items -->
      <div class="card" id="autoconfig-login-card" style="display:none;">
        <div class="card-title" id="autoconfig-login-title">Login Items</div>
        <div class="item-list" id="autoconfig-login-matched"></div>
        <div class="card-collapsible" id="autoconfig-login-other-section" style="display:none;">
          <button type="button" class="card-title card-collapse-trigger" onclick="autoconfigToggleScanSection('login')" style="font-size:12px;margin-top:8px;">
            <span class="card-collapse-icon" id="autoconfig-login-other-icon">▶</span>
            <span id="autoconfig-login-other-label">Also found on this Mac</span>
          </button>
          <div id="autoconfig-login-other-body" style="display:none;">
            <div class="item-list" id="autoconfig-login-unmatched"></div>
          </div>
        </div>
      </div>

      <!-- System Extensions -->
      <div class="card" id="autoconfig-sysext-card" style="display:none;">
        <div class="card-title" id="autoconfig-sysext-title">System Extensions</div>
        <div class="item-list" id="autoconfig-sysext-matched"></div>
        <div class="card-collapsible" id="autoconfig-sysext-other-section" style="display:none;">
          <button type="button" class="card-title card-collapse-trigger" onclick="autoconfigToggleScanSection('sysext')" style="font-size:12px;margin-top:8px;">
            <span class="card-collapse-icon" id="autoconfig-sysext-other-icon">▶</span>
            <span id="autoconfig-sysext-other-label">Also found on this Mac</span>
          </button>
          <div id="autoconfig-sysext-other-body" style="display:none;">
            <div class="item-list" id="autoconfig-sysext-unmatched"></div>
          </div>
        </div>
      </div>

      <div class="info-box" style="margin-top:12px;font-size:12px;">
        <strong>Something missing?</strong> Expand "Also found on this Mac" to see all entries detected on your Mac. Check any item to include it in the profile.
      </div>
```

Keep the existing "Add permission entry" card, "Profile name" card, and footer buttons after this block — they remain unchanged.

- [ ] **Step 2: Add the toggle and render functions**

Add in the JS section:

```javascript
function autoconfigToggleScanSection(category) {
    var body = document.getElementById('autoconfig-' + category + '-other-body');
    var icon = document.getElementById('autoconfig-' + category + '-other-icon');
    if (!body) return;
    var open = body.style.display === 'none';
    body.style.display = open ? '' : 'none';
    if (icon) icon.textContent = open ? '▼' : '▶';
}

function autoconfigRenderScanResults(data) {
    autoconfigScanData = data;
    var bundleId = autoconfigSearchTerm;

    // -- TCC --
    var tccItems = (data.tcc_raw || []);
    var tccFiltered = autoconfigCascadeFilter(tccItems, bundleId, function (e) {
        return (e.resolved_bundle_id || '') + ' ' + (e.client || '');
    });
    autoconfigRenderCategory('tcc', tccFiltered, function (e, checked) {
        var svc = TCC_DISPLAY_NAMES[e.service] || e.service;
        return '<label><input type="checkbox" ' + (checked ? 'checked' : '') + ' data-client="' + esc(e.client) + '" data-service="' + esc(e.service) + '"> ' + esc(e.client) + ' — ' + esc(svc) + '</label>';
    });

    // -- Notifications --
    var notifItems = (data.notifications || []);
    var notifFiltered = autoconfigCascadeFilter(notifItems, bundleId, function (e) { return e.original_id || ''; });
    autoconfigRenderCategory('notif', notifFiltered, function (e, checked) {
        return '<label><input type="checkbox" ' + (checked ? 'checked' : '') + ' data-id="' + esc(e.original_id) + '"> ' + esc(e.original_id) + '</label>';
    });

    // -- Login Items --
    var loginItems = (data.login_items || []);
    var loginFiltered = autoconfigCascadeFilter(loginItems, bundleId, function (e) { return e.source_file || ''; });
    autoconfigRenderCategory('login', loginFiltered, function (e, checked) {
        return '<label><input type="checkbox" ' + (checked ? 'checked' : '') + ' data-team-id="' + esc(e.team_id) + '"> ' + esc(e.source_file) + ' (Team: ' + esc(e.team_id) + ')</label>';
    });

    // -- System Extensions --
    var sysextItems = (data.system_extensions || []);
    var sysextFiltered = autoconfigCascadeFilter(sysextItems, bundleId, function (e) { return e.identifier || ''; });
    autoconfigRenderCategory('sysext', sysextFiltered, function (e, checked) {
        var types = [];
        if (e.endpoint_security) types.push('Endpoint Security');
        if (e.network_extension) types.push('Network Extension');
        return '<label><input type="checkbox" ' + (checked ? 'checked' : '') + ' data-ident="' + esc(e.identifier) + '"> ' + esc(e.identifier) + (types.length ? ' (' + types.join(', ') + ')' : '') + '</label>';
    });

    document.getElementById('autoconfig-after-drop').style.display = '';
}

function autoconfigRenderCategory(category, filtered, renderFn) {
    var card = document.getElementById('autoconfig-' + category + '-card');
    var matchedEl = document.getElementById('autoconfig-' + category + '-matched');
    var unmatchedEl = document.getElementById('autoconfig-' + category + '-unmatched');
    var otherSection = document.getElementById('autoconfig-' + category + '-other-section');
    var otherLabel = document.getElementById('autoconfig-' + category + '-other-label');
    var otherBody = document.getElementById('autoconfig-' + category + '-other-body');
    var titleEl = document.getElementById('autoconfig-' + category + '-title');
    var total = filtered.matched.length + filtered.unmatched.length;
    if (total === 0) { card.style.display = 'none'; return; }
    card.style.display = '';
    var titles = { tcc: 'TCC Permissions', notif: 'Notifications', login: 'Login Items', sysext: 'System Extensions' };
    titleEl.textContent = titles[category] + ' (' + filtered.matched.length + ' matched, ' + filtered.unmatched.length + ' other)';
    matchedEl.innerHTML = filtered.matched.map(function (e) { return '<div class="item-row">' + renderFn(e, true) + '</div>'; }).join('');
    if (filtered.unmatched.length > 0) {
        otherSection.style.display = '';
        otherLabel.textContent = 'Also found on this Mac (' + filtered.unmatched.length + ')';
        unmatchedEl.innerHTML = filtered.unmatched.map(function (e) { return '<div class="item-row">' + renderFn(e, false) + '</div>'; }).join('');
        // If no matches, expand the other section by default
        if (filtered.matched.length === 0) {
            otherBody.style.display = '';
            var icon = document.getElementById('autoconfig-' + category + '-other-icon');
            if (icon) icon.textContent = '▼';
        }
    } else {
        otherSection.style.display = 'none';
    }
}
```

- [ ] **Step 3: Update `startPollForFull` to call `autoconfigRenderScanResults`**

Replace the success handler in `startPollForFull` (lines 571-576) with:

```javascript
          document.getElementById('autoconfig-permission-error').style.display = 'none';
          var tccCount = json.tcc_raw ? json.tcc_raw.length : 0;
          var notifCount = json.notifications ? json.notifications.length : 0;
          statusEl.className = 'info-box';
          statusEl.style.display = 'block';
          statusEl.textContent = 'Scan complete. Found ' + tccCount + ' TCC entries, ' + notifCount + ' notifications. Review below.';
          autoconfigRenderScanResults(json);
```

- [ ] **Step 4: Commit**

```bash
git add app/templates/tools/auto_configurator.html
git commit -m "feat(autoconfig): scan results UI with matched/unmatched sections

Add category cards for TCC, notifications, login items, and system
extensions. Each card shows matched entries (checked) and a collapsible
'Also found' section for unmatched entries. Cascading filter determines
which entries match the dropped app's bundle ID."
```

---

### Task 5: Update profile generation to use scan results with resolve

**Files:**
- Modify: `app/templates/tools/auto_configurator.html` (autoconfigGenerate function)

- [ ] **Step 1: Replace `autoconfigGenerate` to collect from checkboxes and POST /resolve**

Replace the entire `window.autoconfigGenerate` function with:

```javascript
window.autoconfigGenerate = function () {
    // Collect checked TCC clients
    var tccCard = document.getElementById('autoconfig-tcc-card');
    var checkedTCC = [];
    if (tccCard) {
        var tccChecks = tccCard.querySelectorAll('input[type="checkbox"]:checked[data-client]');
        for (var i = 0; i < tccChecks.length; i++) {
            checkedTCC.push(tccChecks[i].getAttribute('data-client'));
        }
    }

    // Collect checked notifications
    var notifCard = document.getElementById('autoconfig-notif-card');
    var checkedNotifs = [];
    if (notifCard) {
        var notifChecks = notifCard.querySelectorAll('input[type="checkbox"]:checked[data-id]');
        for (var i = 0; i < notifChecks.length; i++) {
            checkedNotifs.push({ original_id: notifChecks[i].getAttribute('data-id') });
        }
    }

    // Collect checked login items
    var loginCard = document.getElementById('autoconfig-login-card');
    var checkedLogins = [];
    if (loginCard) {
        var loginChecks = loginCard.querySelectorAll('input[type="checkbox"]:checked[data-team-id]');
        for (var i = 0; i < loginChecks.length; i++) {
            var tid = loginChecks[i].getAttribute('data-team-id');
            if (checkedLogins.indexOf(tid) === -1) checkedLogins.push(tid);
        }
    }

    // Collect checked system extensions from scan data
    var sysextCard = document.getElementById('autoconfig-sysext-card');
    var checkedSysexts = [];
    if (sysextCard && autoconfigScanData) {
        var sysextChecks = sysextCard.querySelectorAll('input[type="checkbox"]:checked[data-ident]');
        var allSysexts = autoconfigScanData.system_extensions || [];
        for (var i = 0; i < sysextChecks.length; i++) {
            var ident = sysextChecks[i].getAttribute('data-ident');
            var ext = allSysexts.find(function (e) { return e.identifier === ident; });
            if (ext) checkedSysexts.push(ext);
        }
    }

    // Also include manually-added entries from the old Add Entry flow
    var manualEntries = autoconfigEntries || [];

    if (!checkedTCC.length && !manualEntries.length && !checkedNotifs.length && !checkedLogins.length && !checkedSysexts.length) {
        alert('Select at least one item or add a permission entry.');
        return;
    }

    var statusEl = document.getElementById('autoconfig-analyze-status');

    function buildAndDownload(resolvedEntries) {
        // Merge manual entries with resolved TCC entries
        var allTCCEntries = manualEntries.concat(resolvedEntries || []);
        var payloadContent = [];
        var servicesPayload = {};
        allTCCEntries.forEach(function (e) {
            var item = { Allowed: true, CodeRequirement: e.codeRequirement || e.code_requirement, Identifier: e.identifier, IdentifierType: 'bundleID', StaticCode: false };
            var perms = e.permissions || [];
            perms.forEach(function (profileKey) {
                if (!servicesPayload[profileKey]) servicesPayload[profileKey] = [];
                servicesPayload[profileKey].push(item);
            });
        });
        if (Object.keys(servicesPayload).length) {
            payloadContent.push({
                PayloadDisplayName: 'Privacy Preferences Policy Control',
                PayloadIdentifier: 'com.apple.TCC.configuration-profile-policy.' + uuid(),
                PayloadType: 'com.apple.TCC.configuration-profile-policy',
                PayloadUUID: uuid(),
                PayloadVersion: 1,
                Services: servicesPayload
            });
        }
        if (checkedLogins.length) {
            payloadContent.push({
                PayloadDisplayName: 'Managed Login Items',
                PayloadIdentifier: 'com.apple.servicemanagement.' + uuid(),
                PayloadType: 'com.apple.servicemanagement',
                PayloadUUID: uuid(),
                PayloadVersion: 1,
                Rules: checkedLogins.map(function (teamId) { return { RuleType: 'TeamIdentifier', RuleValue: teamId }; })
            });
        }
        if (checkedNotifs.length) {
            payloadContent.push({
                PayloadDisplayName: 'Notifications',
                PayloadIdentifier: 'com.apple.notificationsettings.' + uuid(),
                PayloadType: 'com.apple.notificationsettings',
                PayloadUUID: uuid(),
                PayloadVersion: 1,
                NotificationSettings: checkedNotifs.map(function (n) {
                    return {
                        AlertType: 2,
                        BadgesEnabled: true,
                        BundleIdentifier: n.original_id,
                        CriticalAlertEnabled: false,
                        NotificationsEnabled: true,
                        PreviewType: 0,
                        ShowInCarPlay: false,
                        ShowInLockScreen: false,
                        ShowInNotificationCenter: true,
                        SoundsEnabled: true
                    };
                })
            });
        }
        checkedSysexts.forEach(function (ext) {
            var teamId = ext.team_id || '';
            var ident = ext.identifier || '';
            var endpointSecurity = ext.endpoint_security;
            var networkExt = ext.network_extension;
            if (!teamId || (!endpointSecurity && !networkExt)) return;
            var types = [];
            if (endpointSecurity) types.push('EndpointSecurityExtension');
            if (networkExt) types.push('NetworkExtension');
            payloadContent.push({
                PayloadDisplayName: 'System Extension Policy',
                PayloadIdentifier: 'com.apple.system-extension-policy.' + uuid(),
                PayloadType: 'com.apple.system-extension-policy',
                PayloadUUID: uuid(),
                PayloadVersion: 1,
                PayloadOrganization: 'iStore Business',
                AllowUserOverrides: true,
                AllowedSystemExtensionTypes: (function () { var o = {}; o[teamId] = types; return o; })(),
                AllowedSystemExtensions: (function () { var o = {}; o[teamId] = [ident]; return o; })()
            });
            if (networkExt && ext.filter_data_provider_designated_requirement) {
                payloadContent.push({
                    PayloadDisplayName: 'Web Content Filter',
                    PayloadIdentifier: 'com.apple.webcontent-filter.' + uuid(),
                    PayloadType: 'com.apple.webcontent-filter',
                    PayloadUUID: uuid(),
                    PayloadVersion: 1,
                    FilterDataProviderBundleIdentifier: ident,
                    FilterDataProviderDesignatedRequirement: ext.filter_data_provider_designated_requirement,
                    FilterSockets: true,
                    FilterType: 'Plugin',
                    PluginBundleID: ext.app_identifier || '',
                    UserDefinedName: 'Web Content Filter'
                });
            }
        });
        if (!payloadContent.length) {
            alert('No payload content to include in the profile.');
            return;
        }
        var profileName = document.getElementById('autoconfig-profile-name').value.trim() || 'Permissions';
        var config = {
            PayloadContent: payloadContent,
            PayloadDisplayName: profileName,
            PayloadIdentifier: 'com.istorebusiness.autoconfig.' + uuid(),
            PayloadType: 'Configuration',
            PayloadUUID: uuid(),
            PayloadVersion: 1,
            PayloadOrganization: 'iStore Business'
        };
        var filename = (profileName.replace(/[^\w\-]/g, '_') || 'autoconfig') + '.mobileconfig';
        download(filename, buildPlistDoc(config), 'application/x-apple-aspen-config');

        // Sequoia NonRemovable system extensions profile
        if (checkedSysexts.length > 0) {
            var nonRemovable = {};
            checkedSysexts.forEach(function (ext) {
                var tid = ext.team_id || '';
                var ident = ext.identifier || '';
                if (!tid || !ident) return;
                if (!nonRemovable[tid]) nonRemovable[tid] = [];
                if (nonRemovable[tid].indexOf(ident) === -1) nonRemovable[tid].push(ident);
            });
            if (Object.keys(nonRemovable).length > 0) {
                var sequoiaPayload = {
                    AllowUserOverrides: true,
                    NonRemovableSystemExtensions: nonRemovable,
                    PayloadDescription: '',
                    PayloadDisplayName: 'System Extensions',
                    PayloadIdentifier: 'com.apple.system-extension-policy.sequoia.' + uuid(),
                    PayloadOrganization: 'Company Name',
                    PayloadType: 'com.apple.system-extension-policy',
                    PayloadUUID: uuid(),
                    PayloadVersion: 1
                };
                var sequoiaConfig = {
                    PayloadContent: [sequoiaPayload],
                    PayloadDescription: '',
                    PayloadDisplayName: profileName + ' System Extension NonRemovable Settings',
                    PayloadIdentifier: 'com.istorebusiness.autoconfig.sequoia.' + uuid(),
                    PayloadOrganization: 'iStore Business',
                    PayloadRemovalDisallowed: true,
                    PayloadScope: 'System',
                    PayloadType: 'Configuration',
                    PayloadUUID: uuid(),
                    PayloadVersion: 1
                };
                var sequoiaFilename = (profileName.replace(/[^\w\-]/g, '_') || 'autoconfig') + '_Sequoia.mobileconfig';
                download(sequoiaFilename, buildPlistDoc(sequoiaConfig), 'application/x-apple-aspen-config');
            }
        }
    }

    // If we have TCC entries to resolve, POST to /resolve first
    if (checkedTCC.length) {
        if (statusEl) {
            statusEl.className = 'info-box';
            statusEl.style.display = 'block';
            statusEl.textContent = 'Resolving permissions for ' + checkedTCC.length + ' entries...';
        }
        fetch('http://127.0.0.1:' + AUTOCONFIG_POLL_PORT + '/resolve', {
            method: 'POST',
            mode: 'cors',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ clients: checkedTCC })
        }).then(function (res) { return res.json(); }).then(function (json) {
            if (statusEl) statusEl.style.display = 'none';
            buildAndDownload(json.entries || []);
        }).catch(function (err) {
            if (statusEl) {
                statusEl.className = 'warning-box';
                statusEl.textContent = 'Failed to resolve permissions: ' + (err.message || 'Agent not responding. Try dropping the app again.');
                statusEl.style.display = 'block';
            }
        });
    } else {
        buildAndDownload([]);
    }
};
```

- [ ] **Step 2: Remove old `autoconfigMergeAgentEntries` and `autoconfigFindMatchingEntry`**

Delete:
- `autoconfigMergeAgentEntries` function (~lines 748-777)
- `autoconfigFindMatchingEntry` function (~lines 598-610)

These are replaced by `autoconfigRenderScanResults` and `autoconfigCascadeFilter`.

- [ ] **Step 3: Remove old state variables that are no longer needed**

The old `autoconfigNotifications`, `autoconfigLoginItems`, `autoconfigSystemExtensions` variables are no longer used (data is now read from checkboxes at generate time). Remove them:

```javascript
// REMOVE:
var autoconfigNotifications = [];
var autoconfigLoginItems = [];
var autoconfigSystemExtensions = [];
```

Keep `autoconfigEntries` — it's still used by the manual "Add entry" flow.

- [ ] **Step 4: Update `autoconfigImport` to work with new UI**

The import function at ~line 1013 loads a .mobileconfig and populates the UI. Update it to populate the new scan result cards instead of the old state variables. Replace the import handler's success body with logic that constructs a mock scan data object and calls `autoconfigRenderScanResults`:

```javascript
// After parsing the profile and extracting tccPayload, loginPayload, notifPayload, sysExtPayloads:

// Populate manual entries from TCC payload (these have code requirements already)
autoconfigEntries = [];
var seen = {};
Object.keys(tccPayload.Services).forEach(function (profileKey) {
    var items = tccPayload.Services[profileKey] || [];
    items.forEach(function (item) {
        var id = item.Identifier;
        if (!id) return;
        if (!seen[id]) {
            seen[id] = { pathLabel: id, identifier: id, codeRequirement: item.CodeRequirement || '', permissions: [] };
            autoconfigEntries.push(seen[id]);
        }
        if (profileKey && seen[id].permissions.indexOf(profileKey) === -1) seen[id].permissions.push(profileKey);
    });
});

// Build mock scan data for notifications, login items, system extensions
var importedNotifs = (notifPayload && notifPayload.NotificationSettings) ? notifPayload.NotificationSettings.map(function (n) { return { original_id: n.BundleIdentifier }; }) : [];
var importedLogins = (loginPayload && loginPayload.Rules) ? loginPayload.Rules.map(function (r) { return { team_id: r.RuleValue || r.TeamIdentifier || '', source_file: 'imported' }; }).filter(function (l) { return l.team_id; }) : [];
var importedSysexts = [];
sysExtPayloads.forEach(function (p) {
    Object.keys(p.AllowedSystemExtensions || {}).forEach(function (tid) {
        (p.AllowedSystemExtensions[tid] || []).forEach(function (ident) {
            var types = (p.AllowedSystemExtensionTypes || {})[tid] || [];
            var webFilter = content.find(function (q) { return q.PayloadType === 'com.apple.webcontent-filter' && q.FilterDataProviderBundleIdentifier === ident; });
            importedSysexts.push({
                identifier: ident,
                team_id: tid,
                app_identifier: (webFilter && webFilter.PluginBundleID) || '',
                network_extension: types.indexOf('NetworkExtension') !== -1,
                endpoint_security: types.indexOf('EndpointSecurityExtension') !== -1,
                filter_data_provider_designated_requirement: (webFilter && webFilter.FilterDataProviderDesignatedRequirement) || ''
            });
        });
    });
});

// For imported profiles, all items are "matched" (no cascading needed)
autoconfigScanData = { tcc_raw: [], notifications: importedNotifs, login_items: importedLogins, system_extensions: importedSysexts };
// Render with all items as matched
autoconfigSearchTerm = '';
autoconfigRenderScanResults(autoconfigScanData);

// Re-render the manual entries table
autoconfigRender();
autoconfigShowAfterDropIfNeeded();
```

Note: When `autoconfigSearchTerm` is empty, `autoconfigCascadeFilter` returns all items as unmatched. For imported profiles, we want them all checked. Adjust by setting them all checked after render, or pass a special flag. Simplest approach: after calling `autoconfigRenderScanResults`, check all checkboxes in all category cards:

```javascript
['notif', 'login', 'sysext'].forEach(function (cat) {
    var card = document.getElementById('autoconfig-' + cat + '-card');
    if (card) {
        var boxes = card.querySelectorAll('input[type="checkbox"]');
        for (var i = 0; i < boxes.length; i++) boxes[i].checked = true;
        // Expand the "also found" section since all items land there
        var body = document.getElementById('autoconfig-' + cat + '-other-body');
        var icon = document.getElementById('autoconfig-' + cat + '-other-icon');
        if (body) body.style.display = '';
        if (icon) icon.textContent = '▼';
    }
});
```

- [ ] **Step 5: Verify the Flask dev server runs and the page loads**

Run: `python run.py` (requires .env, may need to test on the actual dev machine)

Check: Navigate to the auto_configurator page. The page should load without JS errors. The category cards should be hidden until an app is dropped.

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/auto_configurator.html
git commit -m "feat(autoconfig): scan-based profile generation with resolve

Replace autoconfigGenerate with checkbox-based collection. TCC entries
POST to /resolve for codesign. Notifications, login items, and system
extensions are collected directly from checked items. Import flow
updated to populate new scan result cards."
```

---

## Chunk 3: Cleanup and Edge Cases

### Task 6: Clean up dead code and handle edge cases

**Files:**
- Modify: `agent/Sources/MacAdminToolbox/main.swift` (remove old AgentResponse if unused)
- Modify: `app/templates/tools/auto_configurator.html` (cleanup)

- [ ] **Step 1: Check if `AgentResponse` is still referenced**

Search for `AgentResponse` in the Swift file. It should still be used by `fetchCodeRequirementOnly`. If so, keep it. If not, remove it.

- [ ] **Step 2: Update `autoconfigShowAfterDropIfNeeded` to also check for scan data**

The current function (line ~779-782) only checks `autoconfigEntries.length > 0`. Update it to also show the after-drop container when scan data is present:

```javascript
function autoconfigShowAfterDropIfNeeded() {
    var el = document.getElementById('autoconfig-after-drop');
    if (el && (autoconfigEntries.length > 0 || autoconfigScanData)) el.style.display = '';
}
```

Note: The render functions in Task 4 use the existing `esc()` from `_shared_utils.html` which is already available globally in all tool templates. No new `esc()` definition is needed.

- [ ] **Step 3: Ensure the "Add entry" manual flow still works alongside scan results**

The manual "Add entry" flow uses `autoconfigEntries` array and the old `autoconfigRender()` function. These still exist and the `autoconfigGenerate` function merges `autoconfigEntries` (manual) with resolved TCC entries (from scan checkboxes). Verify:
- The old entries list (`autoconfig-entries-list`) and its header/empty-state are still in the HTML
- `autoconfigRender()` still functions
- The "Add entry" drop zone still calls `autoconfigFetchFromMacForAddForm` which uses the old one-shot `serveResult` path

If the old entries list HTML was removed in Task 4, add it back inside the after-drop div, after the scan result cards:

```html
<div class="card" id="autoconfig-manual-entries-card">
    <div class="card-title">Manual Permission Entries</div>
    <div class="col-header autoconfig-row" id="autoconfig-headers" style="display:none;">
        <span>App / Path</span><span>Identifier</span><span>Permissions</span><span></span>
    </div>
    <div class="item-list" id="autoconfig-entries-list"></div>
    <div class="empty-state" id="autoconfig-empty">No manual entries. Use the drop zone above or "Add permission entry" below.</div>
</div>
```

- [ ] **Step 4: Handle the case where agent is already running when user drops a second app**

In `autoconfigFetchFromMac`, before opening the URL scheme, add a check:

```javascript
function autoconfigFetchFromMac(searchTerm, statusEl) {
    if (!searchTerm || !statusEl) return;
    var errEl = document.getElementById('autoconfig-permission-error');
    if (errEl) errEl.style.display = 'none';
    // Check if agent is still running from a previous drop
    fetch('http://127.0.0.1:' + AUTOCONFIG_POLL_PORT + '/result', { mode: 'cors' }).then(function () {
        // Agent is still alive — warn user
        statusEl.className = 'warning-box';
        statusEl.style.display = 'block';
        statusEl.textContent = 'Agent is still running from a previous scan. Please wait a moment and try again.';
    }).catch(function () {
        // Agent not running — safe to launch
        var url = 'macadmin-toolbox://fetch-tcc?search=' + encodeURIComponent(searchTerm) + '&scope=full';
        window.open(url, '_blank');
        startPollForFull(searchTerm, statusEl);
    });
}
```

- [ ] **Step 5: Build agent and verify**

Run: `cd agent && swift build 2>&1 | tail -20`

Expected: Successful build.

- [ ] **Step 6: Commit**

```bash
git add agent/Sources/MacAdminToolbox/main.swift app/templates/tools/auto_configurator.html
git commit -m "chore(autoconfig): clean up dead code and handle edge cases

Remove unused functions, handle agent-already-running case,
ensure manual entry flow coexists with scan results."
```

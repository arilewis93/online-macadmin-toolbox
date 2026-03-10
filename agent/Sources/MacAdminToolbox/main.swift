import Foundation
import AppKit
import Network
import SQLite3

// MARK: - TCC fetch (mirrors full_toolbox.py Auto Configurator logic)

let tccDBPath = "/Library/Application Support/com.apple.TCC/TCC.db"

func tccServiceToProfileKey(_ service: String) -> String? {
    let prefix = "kTCCService"
    guard service.hasPrefix(prefix) else { return nil }
    return String(service.dropFirst(prefix.count))
}

func bundleID(forPath path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dv", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard let pipe = process.standardError as? Pipe else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        for line in stderr.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Identifier=") {
                let idx = s.index(s.startIndex, offsetBy: "Identifier=".count)
                return String(s[idx...]).trimmingCharacters(in: .whitespaces)
            }
        }
    } catch { return nil }
    return nil
}

func pathForBundleID(_ bundleID: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemCFBundleIdentifier == '\(bundleID)'"]
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        let first = out.split(separator: "\n").first.flatMap { String($0).trimmingCharacters(in: .whitespaces) }
        return first?.isEmpty == false ? first : nil
    } catch { return nil }
}

func codeRequirement(forPath path: String) -> (identifier: String, requirement: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dr", "-", path]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard let pipe = process.standardOutput as? Pipe else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var out = String(data: data, encoding: .utf8) ?? ""
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // codesign -dr can output multiple lines; designated requirement is often on its own line
        var reqLine: String
        if let designatedRange = out.range(of: "designated => ") {
            reqLine = String(out[designatedRange.upperBound...]).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        } else {
            // Fallback: first line that contains a quoted identifier
            let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let found = lines.first(where: { $0.contains("\"") }) else { return nil }
            reqLine = found.replacingOccurrences(of: "designated => ", with: "")
        }
        if reqLine.isEmpty { return nil }
        if let start = reqLine.range(of: "\""), let end = reqLine.range(of: "\"", range: start.upperBound..<reqLine.endIndex) {
            let ident = String(reqLine[start.upperBound..<end.lowerBound])
            return (ident, reqLine)
        }
    } catch { return nil }
    return nil
}

func runSQLite(query: String, dbPath: String) -> Result<[String], Error> {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
        return .failure(NSError(domain: "TCC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not open TCC database"]))
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
        return .failure(NSError(domain: "TCC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not prepare query"]))
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let c0 = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let c1 = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        rows.append("\(c0)|\(c1)")
    }
    return .success(rows)
}

struct AgentEntry: Encodable {
    let path_or_label: String
    let identifier: String
    let code_requirement: String
    let permissions: [String]
}

struct AgentNotification: Encodable {
    let original_id: String
}

struct AgentSystemExtension: Encodable {
    let identifier: String
    let team_id: String
    let app_identifier: String
    let network_extension: Bool
    let endpoint_security: Bool
    let filter_data_provider_designated_requirement: String
}

struct AgentResponse: Encodable {
    let search_term: String?
    let entries: [AgentEntry]
    let notifications: [AgentNotification]?
    let login_items: [String]?
    let system_extensions: [AgentSystemExtension]?
}

// MARK: - Notifications (requires FDA on macOS 15+)

func notificationDBPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
    process.arguments = ["-productVersion"]
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let version = String(data: data, encoding: .utf8)?.split(separator: ".").first.flatMap { Int($0) } ?? 0
    if version >= 15 {
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }
    guard let getconf = try? Process().runAndWait(executable: "/usr/bin/getconf", args: ["DARWIN_USER_DIR"]) else { return nil }
    let base = getconf.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(base)/com.apple.notificationcenter/db2/db"
}

func runSQLiteSingleColumn(query: String, dbPath: String) -> Result<[String], Error> {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
        return .failure(NSError(domain: "TCC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not open database"]))
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
        return .failure(NSError(domain: "TCC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not prepare query"]))
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let c0 = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        rows.append(c0)
    }
    return .success(rows)
}

func fetchNotifications(searchTerm: String) -> [AgentNotification] {
    guard let dbPath = notificationDBPath(), FileManager.default.fileExists(atPath: dbPath),
          case .success(let rows) = runSQLiteSingleColumn(query: "SELECT identifier FROM app;", dbPath: dbPath) else {
        return []
    }
    let searchNorm = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
    var result: [AgentNotification] = []
    for row in rows {
        let ident = row.trimmingCharacters(in: .whitespaces)
        if ident.lowercased().contains(searchNorm) {
            result.append(AgentNotification(original_id: ident))
        }
    }
    return result
}

// MARK: - Login items (LaunchDaemons / LaunchAgents)

func teamID(forPath path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dv", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard let pipe = process.standardError as? Pipe else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if let range = out.range(of: "TeamIdentifier=") {
            let rest = out[range.upperBound...]
            let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "\n" }) ?? rest.endIndex
            return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        }
    } catch { }
    return nil
}

func fetchLoginItems(searchTerm: String) -> [String] {
    var searchNorm = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
    if searchNorm.hasSuffix(".") { searchNorm.removeLast() }
    guard !searchNorm.isEmpty else { return [] }
    let dirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents"]
    var teamIDs: Set<String> = []
    let fm = FileManager.default
    for dir in dirs {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for file in files where file.lowercased().hasSuffix(".plist") && file.lowercased().contains(searchNorm) {
            let plistPath = (dir as NSString).appendingPathComponent(file)
            guard let plistData = fm.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { continue }
            if let args = plist["ProgramArguments"] as? [String] {
                for arg in args where fm.fileExists(atPath: arg) {
                    if let tid = teamID(forPath: arg) { teamIDs.insert(tid) }
                }
            }
            if teamIDs.isEmpty, let program = plist["Program"] as? String, fm.fileExists(atPath: program), let tid = teamID(forPath: program) {
                teamIDs.insert(tid)
            }
        }
    }
    return Array(teamIDs).sorted()
}

// MARK: - System extensions

func fetchSystemExtensions(searchTerm: String) -> [AgentSystemExtension] {
    var searchNorm = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
    if searchNorm.hasSuffix(".") { searchNorm.removeLast() }
    guard !searchNorm.isEmpty else { return [] }
    let plistPath = "/Library/SystemExtensions/db.plist"
    guard let plistData = FileManager.default.contents(atPath: plistPath),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let extensions = plist["extensions"] as? [[String: Any]] else { return [] }
    var result: [AgentSystemExtension] = []
    for ext in extensions {
        let ident = (ext["identifier"] as? String) ?? ""
        if !ident.lowercased().contains(searchNorm) { continue }
        let categories = ext["categories"] as? [String] ?? []
        let endpointSecurity = categories.contains("com.apple.system_extension.endpoint_security")
        let networkExt = categories.contains("com.apple.system_extension.network_extension")
        let originPath = ext["originPath"] as? String ?? ""
        var teamId = ""
        var filterReq = ""
        if !originPath.isEmpty {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            proc.arguments = ["-dr", "-", originPath]
            proc.standardError = FileHandle.nullDevice
            proc.standardOutput = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if let pipe = proc.standardOutput as? Pipe {
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    filterReq = String(data: d, encoding: .utf8)?.replacingOccurrences(of: "designated => ", with: "").split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                }
            }
            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            proc2.arguments = ["-dv", originPath]
            proc2.standardOutput = FileHandle.nullDevice
            proc2.standardError = Pipe()
            if (try? proc2.run()) != nil {
                proc2.waitUntilExit()
                if let pipe = proc2.standardError as? Pipe {
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: d, encoding: .utf8) ?? ""
                    if let r = out.range(of: "TeamIdentifier=") {
                        let rest = out[r.upperBound...]
                        let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "\n" }) ?? rest.endIndex
                        teamId = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        var appIdentifier = ""
        if networkExt, let refs = ext["references"] as? [[String: Any]], let first = refs.first {
            appIdentifier = first["appIdentifier"] as? String ?? ""
        }
        result.append(AgentSystemExtension(
            identifier: ident,
            team_id: teamId,
            app_identifier: appIdentifier,
            network_extension: networkExt,
            endpoint_security: endpointSecurity,
            filter_data_provider_designated_requirement: filterReq
        ))
    }
    return result
}

extension Process {
    func runAndWait(executable: String, args: [String]) throws -> String {
        executableURL = URL(fileURLWithPath: executable)
        arguments = args
        standardError = FileHandle.nullDevice
        let pipe = Pipe()
        standardOutput = pipe
        try run()
        waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

func codeRequirementOrNil(forPath path: String) -> (identifier: String, requirement: String)? {
    if let cr = codeRequirement(forPath: path) { return cr }
    if path.contains(".app/"), let range = path.range(of: ".app/") {
        let appPathStr = String(path[..<range.upperBound].dropLast())
        return codeRequirement(forPath: appPathStr)
    }
    return nil
}

func fetchTCC(searchTerm: String) -> [AgentEntry] {
    var searchNorm = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
    if searchNorm.hasSuffix(".") { searchNorm.removeLast() }
    guard !searchNorm.isEmpty else { return [] }
    var pathToServices: [String: Set<String>] = [:]

    guard case .success(let lines) = runSQLite(query: "SELECT client, service FROM access;", dbPath: tccDBPath) else {
        return []
    }

    for line in lines {
        let parts = line.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        let client = parts[0]
        let service = parts[1]
        let isPath = client.hasPrefix("/")
        let resolvedBID: String?
        let path: String
        if isPath {
            resolvedBID = bundleID(forPath: client)
            path = client
        } else {
            resolvedBID = client
            guard let p = pathForBundleID(client) else { continue }
            path = p
        }
        guard let bid = resolvedBID, !bid.isEmpty else { continue }
        let bidLower = bid.lowercased()
        if !bidLower.contains(searchNorm) && !bidLower.hasPrefix(searchNorm) { continue }
        guard let profileKey = tccServiceToProfileKey(service), !profileKey.isEmpty else { continue }
        guard codeRequirementOrNil(forPath: path) != nil else { continue }
        pathToServices[path, default: []].insert(profileKey)
    }

    let entries: [AgentEntry] = pathToServices.compactMap { path, perms in
        guard let cr = codeRequirementOrNil(forPath: path), !cr.identifier.isEmpty, !cr.requirement.isEmpty else { return nil }
        return AgentEntry(
            path_or_label: path,
            identifier: cr.identifier,
            code_requirement: cr.requirement,
            permissions: Array(perms).sorted()
        )
    }
    return entries
}

func fetchAll(searchTerm: String) -> AgentResponse {
    let entries = fetchTCC(searchTerm: searchTerm)
    let notifications = fetchNotifications(searchTerm: searchTerm)
    let loginItems = fetchLoginItems(searchTerm: searchTerm)
    let systemExtensions = fetchSystemExtensions(searchTerm: searchTerm)
    return AgentResponse(
        search_term: searchTerm,
        entries: entries,
        notifications: notifications.isEmpty ? nil : notifications,
        login_items: loginItems.isEmpty ? nil : loginItems,
        system_extensions: systemExtensions.isEmpty ? nil : systemExtensions
    )
}

/// Fetch only TCC/code requirement data (for Add-form drop). No notifications, login items, or system extensions.
func fetchCodeRequirementOnly(searchTerm: String) -> AgentResponse {
    let entries = fetchTCC(searchTerm: searchTerm)
    return AgentResponse(
        search_term: searchTerm,
        entries: entries,
        notifications: nil,
        login_items: nil,
        system_extensions: nil
    )
}

// MARK: - Permission check (Full Disk Access)

let fullDiskAccessSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

/// Returns nil if we have permission to read TCC; otherwise returns the error message to show.
func checkTCCPermission() -> String? {
    switch runSQLite(query: "SELECT 1 LIMIT 1;", dbPath: tccDBPath) {
    case .success:
        return nil
    case .failure:
        return "Full Disk Access is required to read Privacy (TCC) and notification data. Please grant Full Disk Access to this app in System Settings → Privacy & Security → Full Disk Access."
    }
}

/// Open System Settings to Full Disk Access pane.
func openFullDiskAccessSettings() {
    if let url = URL(string: fullDiskAccessSettingsURL) {
        NSWorkspace.shared.open(url)
    }
}

/// Error payload returned on port 8765 when permission is missing (so the webpage can show it).
struct AgentErrorResponse: Encodable {
    let error: String
    let permission_required: Bool
}

func showPermissionErrorWindow(message: String) {
    DispatchQueue.main.async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permission Required"
        window.center()
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        let text = NSTextField(labelWithString: message)
        text.frame = NSRect(x: 24, y: 100, width: 432, height: 60)
        text.autoresizingMask = [.minYMargin, .width]
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = 432
        text.isEditable = false
        text.isBordered = false
        text.drawsBackground = false
        contentView.addSubview(text)

        let openAction = { [weak window] in
            openFullDiskAccessSettings()
            window?.close()
        }
        let handler = BlockHandler(openAction)
        objc_setAssociatedObject(window, &blockHandlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
        let button = NSButton(title: "Open Full Disk Access Settings", target: handler, action: #selector(BlockHandler.invoke))
        button.frame = NSRect(x: 24, y: 40, width: 220, height: 32)
        button.bezelStyle = .rounded
        contentView.addSubview(button)

        window.contentView?.addSubview(contentView)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private var blockHandlerKey: UInt8 = 0
private class BlockHandler: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}

// MARK: - HTTP server on 8765

let resultPort: UInt16 = 8765

func serveResult(jsonData: Data, terminateAfter: Bool = true) {
    let queue = DispatchQueue(label: "server")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else { return }
    let body = jsonData
    let headerStr = [
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "Content-Length: \(body.count)",
        "Access-Control-Allow-Origin: *",
        "",
        ""
    ].joined(separator: "\r\n")
    let responseData = headerStr.data(using: .utf8)! + body
    listener.newConnectionHandler = { conn in
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            conn.send(content: responseData, completion: .contentProcessed { _ in
                conn.cancel()
                listener.cancel()
                if terminateAfter {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            })
        }
    }
    listener.start(queue: queue)
    if terminateAfter {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            listener.cancel()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // If we were opened with a URL, it will come in application(_:open:)
        // If not, open the toolbox in the browser and quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.handledURL {
                if let url = URL(string: "https://online-macadmin-toolbox.onrender.com/dashboard") {
                    NSWorkspace.shared.open(url)
                }
                NSApp.terminate(nil)
            }
        }
    }

    var handledURL = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "macadmin-toolbox" else { return }
        let host = url.host ?? ""

        // Ping: confirm the agent is registered and running
        if host == "ping" {
            handledURL = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload: [String: Any] = ["agent": true]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                serveResult(jsonData: data)
            }
            return
        }

        // Check Full Disk Access status and open settings if missing
        if host == "check-fda" {
            handledURL = true
            let hasFDA = checkTCCPermission() == nil
            if !hasFDA {
                openFullDiskAccessSettings()
            }
            let payload: [String: Any] = ["agent": true, "full_disk_access": hasFDA]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                serveResult(jsonData: data)
            }
            return
        }

        // Open Full Disk Access settings (from webpage button or direct URL)
        if host == "open-full-disk-access" {
            handledURL = true
            openFullDiskAccessSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }

        if host == "intune-base-build" || host == "serial-killer" || host == "intune-procreate" || host == "intune-assign" {
            handledURL = true
            startIntuneServer()
            return
        }

        if host == "dmg-browse" {
            handledURL = true
            startBrowseServer()
            return
        }

        if host == "dmg-find" {
            handledURL = true
            let query = url.query ?? ""
            let name = query
                .split(separator: "&")
                .first(where: { $0.hasPrefix("name=") })
                .map { $0.dropFirst(5) }
                .map { String($0).removingPercentEncoding ?? String($0) } ?? ""
            guard !name.isEmpty else { return }
            startFindServer(filename: name)
            return
        }

        if host == "dmg-packager" {
            handledURL = true
            let query = url.query ?? ""
            let params = query.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    dict[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
            let dmgPath = params["path"] ?? ""
            let mode = params["mode"] ?? "generic"
            guard !dmgPath.isEmpty else { return }
            startDMGPackagerServer(dmgPath: dmgPath, mode: mode)
            return
        }

        guard host == "fetch-tcc" else { return }
        let query = url.query ?? ""
        let search = query
            .split(separator: "&")
            .first(where: { $0.hasPrefix("search=") })
            .map { $0.dropFirst(7) }
            .map { String($0).removingPercentEncoding ?? "" } ?? ""
        guard !search.isEmpty else { return }
        let scopeFull = !query.split(separator: "&").contains(where: { $0.hasPrefix("scope=") && ($0.dropFirst(6).removingPercentEncoding ?? "").lowercased() == "code_requirement" })
        handledURL = true

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
            let response = scopeFull ? fetchAll(searchTerm: search) : fetchCodeRequirementOnly(searchTerm: search)
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
}

// MARK: - DMG Packager

struct DMGPackagerState {
    var state: String = "idle"       // idle, running, done, error
    var step: String = ""            // current step description
    var log: [String] = []
    var outputPkg: String = ""
    var pkgSize: Int64 = 0
    var error: String = ""

    var statusResponse: [String: Any] {
        return [
            "state": state,
            "step": step,
            "log": log,
            "output_pkg": outputPkg,
            "pkg_size": pkgSize,
            "error": error,
        ]
    }
}

private var dmgState = DMGPackagerState()
private let dmgStateQueue = DispatchQueue(label: "com.macadmin.dmgState")
private let dmgWorkQueue = DispatchQueue(label: "com.macadmin.dmgWork", qos: .userInitiated)

// Browse state for file picker
struct DMGBrowseResult {
    var path: String = ""
    var cancelled: Bool = false
    var ready: Bool = false
}

private var browseResult = DMGBrowseResult()
private let browseQueue = DispatchQueue(label: "com.macadmin.dmgBrowse")

func openDMGFilePicker() {
    DispatchQueue.main.async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Select a DMG"
        panel.allowedFileTypes = ["dmg"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let response = panel.runModal()
        browseQueue.sync {
            if response == .OK, let url = panel.url {
                browseResult = DMGBrowseResult(path: url.path, cancelled: false, ready: true)
            } else {
                browseResult = DMGBrowseResult(path: "", cancelled: true, ready: true)
            }
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

func startBrowseServer() {
    browseQueue.sync { browseResult = DMGBrowseResult() }
    openDMGFilePicker()

    let queue = DispatchQueue(label: "com.macadmin.dmgBrowseServer")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else { return }

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
            if request.path == "/browse-result" {
                let result = browseQueue.sync { browseResult }
                if result.ready {
                    var dict: [String: Any] = [:]
                    if result.cancelled {
                        dict["cancelled"] = true
                    } else {
                        dict["path"] = result.path
                    }
                    let resp = jsonResponse(dict)
                    connection.send(content: resp, completion: .contentProcessed { _ in
                        connection.cancel()
                        listener.cancel()
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    })
                } else {
                    let resp = jsonResponse(["waiting": true])
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else {
                let resp = jsonResponse(["error": "Not found"], status: "404 Not Found")
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    listener.start(queue: queue)

    // Timeout after 2 minutes
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        listener.cancel()
        NSApp.terminate(nil)
    }
}

func findDMGByName(_ filename: String) -> String? {
    // Search common locations first for an exact match
    let home = NSHomeDirectory()
    let searchDirs = [
        home + "/Downloads",
        home + "/Desktop",
        home + "/Documents",
        "/tmp",
    ]
    let fm = FileManager.default
    for dir in searchDirs {
        let candidate = (dir as NSString).appendingPathComponent(filename)
        if fm.fileExists(atPath: candidate) { return candidate }
    }
    // Fallback: use mdfind for a Spotlight search
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    proc.arguments = ["-name", filename]
    proc.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    proc.standardOutput = pipe
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    for line in output.split(separator: "\n") {
        let path = line.trimmingCharacters(in: .whitespaces)
        if path.hasSuffix(filename) && fm.fileExists(atPath: path) { return path }
    }
    return nil
}

func startFindServer(filename: String) {
    let queue = DispatchQueue(label: "com.macadmin.dmgFindServer")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else { return }

    // Run the search on a background thread
    var findResult: [String: Any]? = nil
    let findQueue = DispatchQueue(label: "com.macadmin.dmgFind")
    DispatchQueue.global(qos: .userInitiated).async {
        if let path = findDMGByName(filename) {
            findQueue.sync { findResult = ["path": path] }
        } else {
            findQueue.sync { findResult = ["error": "Could not find \(filename) on this Mac. Try clicking the drop zone to browse manually."] }
        }
    }

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
            if request.path == "/find-result" {
                let result = findQueue.sync { findResult }
                if let result = result {
                    let resp = jsonResponse(result)
                    connection.send(content: resp, completion: .contentProcessed { _ in
                        connection.cancel()
                        listener.cancel()
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    })
                } else {
                    // Still searching
                    let resp = jsonResponse(["waiting": true])
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else {
                let resp = jsonResponse(["error": "Not found"], status: "404 Not Found")
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    listener.start(queue: queue)

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        listener.cancel()
        NSApp.terminate(nil)
    }
}

func dmgLog(_ message: String) {
    dmgStateQueue.sync { dmgState.log.append(message) }
}

func dmgSetStep(_ step: String) {
    dmgStateQueue.sync { dmgState.step = step }
    dmgLog("▶ \(step)")
}

func runShellCommand(_ args: [String], env: [String: String]? = nil) throws -> (exitCode: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: args[0])
    proc.arguments = Array(args.dropFirst())
    if let env = env { proc.environment = env }
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (proc.terminationStatus, output)
}

func listVolumes() -> Set<String> {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }
    return Set(items.filter { $0 != "Macintosh HD" && $0 != ".DS_Store" })
}

func detectMountpoint(volumesBefore: Set<String>, dmgPath: String) -> String? {
    let after = listVolumes()
    let newVols = after.subtracting(volumesBefore)
    for vol in newVols {
        let path = "/Volumes/\(vol)"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
    }
    // Fallback: parse hdiutil info
    guard let result = try? runShellCommand(["/usr/bin/hdiutil", "info", "-plist"]),
          result.exitCode == 0,
          let plistData = result.output.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let images = plist["images"] as? [[String: Any]] else { return nil }
    for image in images {
        if image["image-path"] as? String == dmgPath,
           let entities = image["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mp = entity["mount-point"] as? String { return mp }
            }
        }
    }
    return nil
}

func findInstallApp(in directory: String, maxDepth: Int = 2) -> String? {
    let fm = FileManager.default
    let baseURL = URL(fileURLWithPath: directory)
    guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
    while let url = enumerator.nextObject() as? URL {
        let relPath = url.path.dropFirst(directory.count + 1)
        let depth = relPath.split(separator: "/").count
        if depth > maxDepth { enumerator.skipDescendants(); continue }
        if url.lastPathComponent == "Install.app" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.path
            }
        }
    }
    return nil
}

func findPKGFiles(in directory: String) -> [String] {
    let fm = FileManager.default
    let baseURL = URL(fileURLWithPath: directory)
    var pkgs: [String] = []
    guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: nil, options: []) else { return [] }
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension.lowercased() == "pkg" {
            pkgs.append(url.path)
        }
    }
    return pkgs
}

func createPostinstallScript(at scriptPath: String, installBase: String) {
    let script = """
    #!/bin/bash
    set -e
    INSTALL_BASE="\(installBase)"
    LOG_FILE="/var/log/dmg_packager_install.log"
    log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
    log_message "Starting postinstall script..."
    PKG_COUNT=0; INSTALLED_COUNT=0
    while IFS= read -r -d '' pkg_file; do
        PKG_COUNT=$((PKG_COUNT + 1))
        log_message "Found PKG file: $pkg_file"
        if /usr/sbin/installer -pkg "$pkg_file" -target /; then
            INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
            log_message "Successfully installed: $pkg_file"
        else
            log_message "ERROR: Failed to install $pkg_file"
            exit 1
        fi
    done < <(find "$INSTALL_BASE" -name "*.pkg" -type f -print0 2>/dev/null || true)
    if [ $PKG_COUNT -eq 0 ]; then
        log_message "No PKG files found in DMG contents."
    else
        log_message "Installed $INSTALLED_COUNT of $PKG_COUNT PKG file(s)"
    fi
    log_message "Cleaning up: $INSTALL_BASE"
    [ -d "$INSTALL_BASE" ] && rm -rf "$INSTALL_BASE"
    log_message "Postinstall completed"
    exit 0
    """
    try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    // Make executable
    let _ = try? runShellCommand(["/bin/chmod", "+x", scriptPath])
}

func runDMGPackager(dmgPath: String, mode: String) {
    let env = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    var mountpoint: String?
    var workdir: String?

    do {
        // Validate file exists
        guard FileManager.default.fileExists(atPath: dmgPath) else {
            throw NSError(domain: "DMGPackager", code: 1, userInfo: [NSLocalizedDescriptionKey: "DMG file not found: \(dmgPath)"])
        }

        // Mount
        dmgSetStep("Mounting DMG")
        let volumesBefore = listVolumes()
        let mountResult = try runShellCommand(["/usr/bin/hdiutil", "attach", dmgPath, "-nobrowse"], env: env)
        if mountResult.exitCode != 0 {
            throw NSError(domain: "DMGPackager", code: 2, userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed: \(mountResult.output)"])
        }
        Thread.sleep(forTimeInterval: 1.0)

        mountpoint = detectMountpoint(volumesBefore: volumesBefore, dmgPath: dmgPath)
        guard let mp = mountpoint else {
            throw NSError(domain: "DMGPackager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to determine mount point"])
        }
        dmgLog("Mounted at: \(mp)")

        // Create temp working directory
        workdir = NSTemporaryDirectory() + "dmg_packager_\(ProcessInfo.processInfo.globallyUniqueString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: workdir!, withIntermediateDirectories: true)

        let payloadDir = workdir! + "/payload"
        let outputPkg: String
        let baseName = (dmgPath as NSString).deletingPathExtension
        outputPkg = baseName + ".pkg"

        if mode == "acronis" {
            // Acronis mode: find Install.app, copy to /var/tmp/infosec/
            dmgSetStep("Finding Install.app")
            guard let installApp = findInstallApp(in: mp) else {
                throw NSError(domain: "DMGPackager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Install.app not found in DMG"])
            }
            dmgLog("Found Install.app at: \(installApp)")

            let targetDir = payloadDir + "/private/var/tmp/infosec/Install.app"
            try fm.createDirectory(atPath: (targetDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

            dmgSetStep("Copying Install.app")
            let copyResult = try runShellCommand(["/usr/bin/ditto", installApp, targetDir], env: env)
            if copyResult.exitCode != 0 {
                throw NSError(domain: "DMGPackager", code: 5, userInfo: [NSLocalizedDescriptionKey: "ditto failed: \(copyResult.output)"])
            }

            // Remove quarantine
            let _ = try? runShellCommand(["/usr/bin/xattr", "-dr", "com.apple.quarantine", targetDir], env: env)

            // Build PKG
            dmgSetStep("Building PKG")
            let pkgResult = try runShellCommand([
                "/usr/bin/pkgbuild",
                "--root", payloadDir,
                "--install-location", "/",
                "--identifier", "com.infosec.installapp",
                "--version", "1.0",
                outputPkg
            ], env: env)
            if pkgResult.exitCode != 0 {
                throw NSError(domain: "DMGPackager", code: 6, userInfo: [NSLocalizedDescriptionKey: "pkgbuild failed: \(pkgResult.output)"])
            }

        } else {
            // Generic mode: copy all contents, create postinstall for embedded PKGs
            let targetDir = payloadDir + "/private/var/tmp/dmg_contents"
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

            dmgSetStep("Copying DMG contents")
            let copyResult = try runShellCommand(["/usr/bin/ditto", mp, targetDir], env: env)
            if copyResult.exitCode != 0 {
                throw NSError(domain: "DMGPackager", code: 5, userInfo: [NSLocalizedDescriptionKey: "ditto failed: \(copyResult.output)"])
            }

            // Remove quarantine
            let _ = try? runShellCommand(["/usr/bin/xattr", "-dr", "com.apple.quarantine", targetDir], env: env)

            // Find embedded PKGs
            let pkgFiles = findPKGFiles(in: targetDir)
            dmgLog("Found \(pkgFiles.count) PKG file(s) in DMG contents")

            // Create postinstall script
            let scriptsDir = workdir! + "/scripts"
            try fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
            createPostinstallScript(at: scriptsDir + "/postinstall", installBase: "/private/var/tmp/dmg_contents")
            dmgLog("Created postinstall script")

            // Build PKG with scripts
            dmgSetStep("Building PKG")
            let pkgResult = try runShellCommand([
                "/usr/bin/pkgbuild",
                "--root", payloadDir,
                "--scripts", scriptsDir,
                "--install-location", "/",
                "--identifier", "com.dmgpackager.contents",
                "--version", "1.0",
                outputPkg
            ], env: env)
            if pkgResult.exitCode != 0 {
                throw NSError(domain: "DMGPackager", code: 6, userInfo: [NSLocalizedDescriptionKey: "pkgbuild failed: \(pkgResult.output)"])
            }
        }

        // Verify output
        guard fm.fileExists(atPath: outputPkg) else {
            throw NSError(domain: "DMGPackager", code: 7, userInfo: [NSLocalizedDescriptionKey: "PKG not found after build"])
        }
        let attrs = try fm.attributesOfItem(atPath: outputPkg)
        let size = (attrs[.size] as? Int64) ?? 0
        dmgLog("PKG created: \(outputPkg) (\(size) bytes)")

        dmgStateQueue.sync {
            dmgState.outputPkg = outputPkg
            dmgState.pkgSize = size
            dmgState.state = "done"
            dmgState.step = "complete"
        }

    } catch {
        dmgLog("Error: \(error.localizedDescription)")
        dmgStateQueue.sync {
            dmgState.error = error.localizedDescription
            dmgState.state = "error"
        }
    }

    // Cleanup
    if let mp = mountpoint {
        let _ = try? runShellCommand(["/usr/bin/hdiutil", "detach", mp], env: env)
        dmgLog("Detached DMG")
    }
    if let wd = workdir, FileManager.default.fileExists(atPath: wd) {
        try? FileManager.default.removeItem(atPath: wd)
        dmgLog("Cleaned up temp directory")
    }
}

func handleDMGPackagerRequest(method: String, path: String, body: Data) -> Data {
    if method == "OPTIONS" {
        return corsPreflightResponse()
    }

    switch path {
    case "/status":
        let status = dmgStateQueue.sync { dmgState.statusResponse }
        return jsonResponse(status)

    default:
        return jsonResponse(["error": "Not found"], status: "404 Not Found")
    }
}

func startDMGPackagerServer(dmgPath: String, mode: String) {
    // Reset state
    dmgStateQueue.sync {
        dmgState = DMGPackagerState()
        dmgState.state = "running"
    }

    let queue = DispatchQueue(label: "com.macadmin.dmgPackagerServer")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else {
        NSLog("Failed to start DMG Packager server on port \(resultPort)")
        return
    }

    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, let request = parseHTTPRequest(data) else {
                connection.cancel()
                return
            }
            let response = handleDMGPackagerRequest(method: request.method, path: request.path, body: request.body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    listener.stateUpdateHandler = { state in
        if case .ready = state {
            NSLog("DMG Packager server listening on port \(resultPort)")
        }
    }

    listener.start(queue: queue)

    // Start packaging on work queue
    dmgWorkQueue.async {
        runDMGPackager(dmgPath: dmgPath, mode: mode)
    }
}

// MARK: - Intune Auth

enum IntuneOperation: String, Encodable {
    case idle, connecting, connected
}

struct IntuneState {
    var operation: IntuneOperation = .idle
    var connected: Bool = false
    var error: String = ""
    var connectStep: String = ""  // sub-step detail during connecting
    var psProcess: Process? = nil

    var statusResponse: [String: Any] {
        return [
            "operation": operation.rawValue,
            "connected": connected,
            "error": error,
            "connectStep": connectStep
        ]
    }
}

private var intuneState = IntuneState()
private let stateQueue = DispatchQueue(label: "com.macadmin.intuneState")
private let intuneWorkQueue = DispatchQueue(label: "com.macadmin.intuneWork", qos: .userInitiated)

// MARK: - PowerShell session helpers

private let localPwshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/powershell").path
private let localPwshBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/powershell/pwsh").path

func installPowerShellIfNeeded() -> (success: Bool, message: String) {
    // Check all known locations
    let knownPaths = ["/usr/local/bin/pwsh", "/opt/homebrew/bin/pwsh", localPwshBin]
    if knownPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
        return (true, "PowerShell already installed")
    }

    // Download official tar.gz (no admin required)
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x64"
    #endif
    let version = "7.5.4"
    let url = "https://github.com/PowerShell/PowerShell/releases/download/v\(version)/powershell-\(version)-osx-\(arch).tar.gz"

    let script = """
    set -e
    mkdir -p '\(localPwshDir)'
    curl -fSL -o /tmp/powershell.tar.gz '\(url)'
    tar zxf /tmp/powershell.tar.gz -C '\(localPwshDir)'
    chmod +x '\(localPwshBin)'
    xattr -rd com.apple.quarantine '\(localPwshDir)' 2>/dev/null || true
    rm -f /tmp/powershell.tar.gz
    '\(localPwshBin)' --version
    """

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-c", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0 {
            return (true, "PowerShell \(version) installed")
        }
        return (false, "Failed to install PowerShell: \(cleanANSI(out).suffix(200))")
    } catch {
        return (false, "Failed to install PowerShell: \(error.localizedDescription)")
    }
}

func installGraphModuleIfNeeded() -> (success: Bool, message: String) {
    let pwshPath = pwshExecutablePath()
    let modules = [
        "Microsoft.Graph.Authentication",
    ]
    let psCommand = """
    $missing = @()
    \(modules.map { "if (!(Get-Module -ListAvailable -Name '\($0)')) { $missing += '\($0)' }" }.joined(separator: "\n"))
    if ($missing.Count -eq 0) { Write-Output 'INSTALLED'; exit 0 }
    foreach ($m in $missing) { Install-Module $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }
    Write-Output 'INSTALLED'
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pwshPath)
    proc.arguments = ["-Command", psCommand]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if out.contains("INSTALLED") {
            return (true, "Microsoft Graph modules ready")
        }
        return (false, "Graph module install issue: \(cleanANSI(out).suffix(200))")
    } catch {
        return (false, "Failed to install Graph modules: \(error.localizedDescription)")
    }
}

func pwshExecutablePath() -> String {
    if FileManager.default.fileExists(atPath: "/usr/local/bin/pwsh") { return "/usr/local/bin/pwsh" }
    if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/pwsh") { return "/opt/homebrew/bin/pwsh" }
    if FileManager.default.fileExists(atPath: localPwshBin) { return localPwshBin }
    return "pwsh"
}

func startPowerShellSession() -> Process? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pwshExecutablePath())
    proc.arguments = ["-NoExit", "-Command", "-"]
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe
    do {
        try proc.run()
        let importCmd = "Import-Module 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue\nWrite-Output '---COMMAND-COMPLETE---'\n"
        stdinPipe.fileHandleForWriting.write(importCmd.data(using: .utf8)!)
        // Read until marker
        let _ = readUntilMarker(handle: stdoutPipe.fileHandleForReading, timeout: 60)
        return proc
    } catch {
        return nil
    }
}

func readUntilMarker(handle: FileHandle, timeout: TimeInterval) -> String {
    let marker = "---COMMAND-COMPLETE---"
    var accumulated = ""
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let data = handle.availableData
        if data.isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
            continue
        }
        accumulated += String(data: data, encoding: .utf8) ?? ""
        if accumulated.contains(marker) {
            // Remove marker from output
            let parts = accumulated.components(separatedBy: marker)
            return parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runPSCommand(_ process: Process, command: String, timeout: TimeInterval = 60) -> String {
    guard let stdinPipe = process.standardInput as? Pipe,
          let stdoutPipe = process.standardOutput as? Pipe else {
        return ""
    }
    // Use $ErrorActionPreference to ensure non-terminating errors don't stop the marker,
    // then always write the marker on its own line after the command completes
    let fullCmd = "$ErrorActionPreference = 'Continue'\n\(command)\nWrite-Output '---COMMAND-COMPLETE---'\n"
    stdinPipe.fileHandleForWriting.write(fullCmd.data(using: .utf8)!)
    let result = readUntilMarker(handle: stdoutPipe.fileHandleForReading, timeout: timeout)
    return cleanANSI(result)
}

func cleanANSI(_ input: String) -> String {
    // Strip ANSI/VT100 escape sequences (ESC[ and bare CSI variants)
    var result = input
    let patterns = [
        "\\x1B\\[\\??[0-9;]*[A-Za-z]",   // ESC [ sequences
        "\\x1B\\].*?\\x07",                // OSC sequences (ESC ] ... BEL)
        "\\x1B[>=]",                        // ESC = / ESC >
        "\\[\\?[0-9;]*[A-Za-z]",           // bare [?1h / [?1l without ESC
    ]
    for pat in patterns {
        if let regex = try? NSRegularExpression(pattern: pat, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - HTTP server infrastructure

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
    guard let str = String(data: data, encoding: .utf8) else { return nil }
    let lines = str.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let path = String(parts[1])

    // Find body after empty line
    var body = Data()
    if let range = str.range(of: "\r\n\r\n") {
        let bodyStr = String(str[range.upperBound...])
        body = bodyStr.data(using: .utf8) ?? Data()
    }
    return HTTPRequest(method: method, path: path, body: body)
}

func jsonResponse(_ dict: [String: Any], status: String = "200 OK") -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    let header = [
        "HTTP/1.1 \(status)",
        "Content-Type: application/json",
        "Content-Length: \(body.count)",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Connection: close",
        "",
        ""
    ].joined(separator: "\r\n")
    return header.data(using: .utf8)! + body
}

func jsonResponseFromData(_ body: Data, status: String = "200 OK") -> Data {
    let header = [
        "HTTP/1.1 \(status)",
        "Content-Type: application/json",
        "Content-Length: \(body.count)",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Connection: close",
        "",
        ""
    ].joined(separator: "\r\n")
    return header.data(using: .utf8)! + body
}

func corsPreflightResponse() -> Data {
    let header = [
        "HTTP/1.1 204 No Content",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Content-Length: 0",
        "Connection: close",
        "",
        ""
    ].joined(separator: "\r\n")
    return header.data(using: .utf8)!
}

// MARK: - Endpoint handlers

func handleConnect(encoder: JSONEncoder, requestedScopes: [String] = []) {
    // Tear down any existing session first
    if let proc = stateQueue.sync(execute: { intuneState.psProcess }), proc.isRunning {
        let _ = runPSCommand(proc, command: "Disconnect-MgGraph", timeout: 10)
        proc.terminate()
    }
    stateQueue.sync {
        intuneState = IntuneState()
        intuneState.operation = .connecting
    }

    intuneWorkQueue.async {
        // Step 1: Install PowerShell
        stateQueue.sync { intuneState.connectStep = "Installing PowerShell" }
        let psResult = installPowerShellIfNeeded()
        guard psResult.success else {
            stateQueue.sync {
                intuneState.error = psResult.message
                intuneState.operation = .idle
            }
            return
        }

        // Step 2: Install Graph Authentication Module
        stateQueue.sync { intuneState.connectStep = "Installing Graph module" }
        let graphResult = installGraphModuleIfNeeded()
        guard graphResult.success else {
            stateQueue.sync {
                intuneState.error = graphResult.message
                intuneState.operation = .idle
            }
            return
        }

        // Step 3: Start PS session
        stateQueue.sync { intuneState.connectStep = "Starting PowerShell session" }
        guard let proc = startPowerShellSession() else {
            stateQueue.sync {
                intuneState.error = "Failed to start PowerShell session"
                intuneState.operation = .idle
            }
            return
        }
        stateQueue.sync { intuneState.psProcess = proc }

        // Default scopes (base build)
        let defaultScopes = [
            "DeviceManagementConfiguration.ReadWrite.All",
            "DeviceManagementApps.ReadWrite.All",
            "DeviceManagementManagedDevices.ReadWrite.All",
            "DeviceManagementServiceConfig.ReadWrite.All",
            "Group.ReadWrite.All",
            "GroupMember.ReadWrite.All",
            "Organization.Read.All",
            "User.Read.All",
            "Directory.ReadWrite.All",
        ]
        let scopes = requestedScopes.isEmpty
            ? defaultScopes.map { "'\($0)'" }.joined(separator: ",")
            : requestedScopes.map { "'\($0)'" }.joined(separator: ",")
        stateQueue.sync { intuneState.connectStep = "Waiting for browser auth" }
        let connectOutput = runPSCommand(proc, command: "Connect-MgGraph -Scopes \(scopes) -NoWelcome", timeout: 120)

        if connectOutput.lowercased().contains("error") || connectOutput.lowercased().contains("fail") {
            stateQueue.sync {
                intuneState.error = connectOutput
                intuneState.operation = .idle
            }
            return
        }

        // Auth succeeded — mark connected. Browser will fetch tenant info via Graph API.
        stateQueue.sync {
            intuneState.connected = true
            intuneState.operation = .connected
        }
    }
}

func handleToken() -> [String: Any] {
    guard let proc = stateQueue.sync(execute: { intuneState.psProcess }), proc.isRunning else {
        return ["error": "Not connected"]
    }
    let connected = stateQueue.sync { intuneState.connected }
    guard connected else {
        return ["error": "Not connected"]
    }

    // Extract bearer token from Invoke-MgGraphRequest response headers
    let tokenOutput = runPSCommand(proc, command: "$resp = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/me' -OutputType HttpResponseMessage; $resp.RequestMessage.Headers.Authorization.Parameter", timeout: 30)

    let token = tokenOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
        return ["error": "Could not retrieve access token"]
    }

    return ["token": token]
}

func handleDisconnect(encoder: JSONEncoder) {
    if let proc = stateQueue.sync(execute: { intuneState.psProcess }), proc.isRunning {
        let _ = runPSCommand(proc, command: "Disconnect-MgGraph", timeout: 15)
        proc.terminate()
    }
    stateQueue.sync {
        intuneState = IntuneState()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        NSApp.terminate(nil)
    }
}

// MARK: - Intune HTTP request routing

func handleIntuneRequest(method: String, path: String, body: Data) -> Data {
    if method == "OPTIONS" {
        return corsPreflightResponse()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    switch path {
    case "/status":
        let status = stateQueue.sync { intuneState.statusResponse }
        return jsonResponse(status)

    case "/connect":
        guard method == "POST" else {
            return jsonResponse(["error": "Method not allowed"], status: "405 Method Not Allowed")
        }
        // Parse requested scopes from body
        var requestedScopes: [String] = []
        if !body.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let scopes = json["scopes"] as? [String] {
            requestedScopes = scopes
        }
        handleConnect(encoder: encoder, requestedScopes: requestedScopes)
        return jsonResponse(["status": "connecting"])

    case "/token":
        let result = handleToken()
        if result["error"] != nil {
            return jsonResponse(result, status: "401 Unauthorized")
        }
        return jsonResponse(result)

    case "/disconnect":
        guard method == "POST" else {
            return jsonResponse(["error": "Method not allowed"], status: "405 Method Not Allowed")
        }
        handleDisconnect(encoder: encoder)
        return jsonResponse(["status": "disconnecting"])

    default:
        return jsonResponse(["error": "Not found"], status: "404 Not Found")
    }
}

// MARK: - Intune server start

func startIntuneServer() {
    let queue = DispatchQueue(label: "com.macadmin.intuneServer")
    guard let port = NWEndpoint.Port(rawValue: resultPort),
          let listener = try? NWListener(using: .tcp, on: port) else {
        NSLog("Failed to start Intune server on port \(resultPort)")
        return
    }

    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, let request = parseHTTPRequest(data) else {
                connection.cancel()
                return
            }
            let response = handleIntuneRequest(method: request.method, path: request.path, body: request.body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            NSLog("Intune server listening on port \(resultPort)")
        case .failed(let error):
            NSLog("Intune server failed: \(error)")
        default:
            break
        }
    }

    listener.start(queue: queue)
}

// MARK: - Main

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

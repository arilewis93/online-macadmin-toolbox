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
        // If not, quit after a short delay so we don't sit in dock
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.handledURL {
                NSApp.terminate(nil)
            }
        }
    }

    var handledURL = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "macadmin-toolbox" else { return }
        let host = url.host ?? ""

        // Open Full Disk Access settings (from webpage button or direct URL)
        if host == "open-full-disk-access" {
            handledURL = true
            openFullDiskAccessSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
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

// MARK: - Main

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

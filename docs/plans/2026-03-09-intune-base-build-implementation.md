# Intune Base Build Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an Intune Base Build tool to the Online MacAdmin Toolbox that automates deployment of configuration files to a client's Intune tenant via a 4-step wizard UI and local Swift agent with PowerShell backend.

**Architecture:** The Swift agent (existing `agent/Sources/MacAdminToolbox/main.swift`) gains a long-lived HTTP server mode triggered by `macadmin-toolbox://intune-base-build`. It installs PowerShell + Microsoft.Graph modules if needed, runs `Connect-MgGraph`, and handles all uploads via existing PowerShell cmdlets from `IntuneBaseBuild.psm1`. The web UI is a new tool template with a 4-step wizard (Connect, Prerequisites, Select Files, Upload).

**Tech Stack:** Swift 5.5+ (agent), Flask/Jinja2 (backend), vanilla JavaScript (frontend), PowerShell 7+ with Microsoft.Graph module (Intune operations)

---

### Task 1: Add IntuneBaseBuild.psm1 to the agent bundle

The agent needs access to the PowerShell module. Copy it into the project so it ships with the agent.

**Files:**
- Create: `agent/Resources/IntuneBaseBuild.psm1` (copy from Mac-Admin-Toolbox)

**Step 1: Copy the module file**

Copy `/Users/aryeh.lewis/PycharmProjects/Mac-Admin-Toolbox/bash/IntuneBaseBuild.psm1` to `agent/Resources/IntuneBaseBuild.psm1`.

**Step 2: Update build_and_sign.sh to include Resources**

Modify `agent/build_and_sign.sh` to copy the Resources directory into the .app bundle:

```bash
# After the existing mkdir lines, add:
cp -R Resources/ "$APP_NAME/Contents/Resources/" 2>/dev/null || true
```

**Step 3: Commit**

```bash
git add agent/Resources/IntuneBaseBuild.psm1 agent/build_and_sign.sh
git commit -m "feat: bundle IntuneBaseBuild.psm1 with agent"
```

---

### Task 2: Add Intune long-lived HTTP server to Swift agent

Add a new URL scheme handler (`intune-base-build`) that starts a persistent HTTP server with JSON API endpoints. The existing `fetch-tcc` one-shot handler stays unchanged.

**Files:**
- Modify: `agent/Sources/MacAdminToolbox/main.swift`

**Step 1: Add Intune state model**

Add these structs after the existing `AgentErrorResponse` struct (~line 428):

```swift
// MARK: - Intune Base Build state

enum IntuneOperation: String, Encodable {
    case idle, connecting, prerequisites, uploading
}

enum ItemStatus: String, Encodable {
    case pending, processing, success, fail
}

struct ProgressItem: Encodable {
    let name: String
    var status: ItemStatus
    var message: String?
}

struct IntuneState {
    var operation: IntuneOperation = .idle
    var connected: Bool = false
    var tenantId: String?
    var tenantName: String?
    var userEmail: String?
    var groupId: String?
    var items: [ProgressItem] = []
    var psProcess: Process?
    var modulePath: String?

    struct StatusResponse: Encodable {
        let operation: String
        let connected: Bool
        let tenantId: String?
        let tenantName: String?
        let userEmail: String?
        let groupId: String?
        let items: [ProgressItem]
    }

    var statusResponse: StatusResponse {
        StatusResponse(
            operation: operation.rawValue,
            connected: connected,
            tenantId: tenantId,
            tenantName: tenantName,
            userEmail: userEmail,
            groupId: groupId,
            items: items
        )
    }
}
```

**Step 2: Add PowerShell session management**

Add PowerShell helper functions after the Intune state model:

```swift
// MARK: - PowerShell session helpers

let intunePort: UInt16 = 8765

func findModulePath() -> String? {
    let bundle = Bundle.main
    if let path = bundle.path(forResource: "IntuneBaseBuild", ofType: "psm1") {
        return path
    }
    // Fallback: look next to the executable
    let execDir = bundle.executableURL?.deletingLastPathComponent().path ?? ""
    let fallback = (execDir as NSString).appendingPathComponent("../Resources/IntuneBaseBuild.psm1")
    return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
}

func installPowerShellIfNeeded() -> (success: Bool, message: String) {
    let pwshPath = "/usr/local/bin/pwsh"
    if FileManager.default.fileExists(atPath: pwshPath) {
        return (true, "PowerShell already installed")
    }
    // Try Homebrew install
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-c", "brew install --cask powershell"]
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
            ? (true, "PowerShell installed")
            : (false, "Failed to install PowerShell via Homebrew")
    } catch {
        return (false, "Failed to run Homebrew: \(error)")
    }
}

func installGraphModuleIfNeeded() -> (success: Bool, message: String) {
    let checkProc = Process()
    checkProc.executableURL = URL(fileURLWithPath: "/usr/local/bin/pwsh")
    checkProc.arguments = ["-NoProfile", "-Command", "if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) { Write-Host 'INSTALLED' }"]
    let pipe = Pipe()
    checkProc.standardOutput = pipe
    checkProc.standardError = FileHandle.nullDevice
    do {
        try checkProc.run()
        checkProc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("INSTALLED") {
            return (true, "Microsoft.Graph module already installed")
        }
    } catch {
        return (false, "Failed to check modules: \(error)")
    }
    // Install
    let installProc = Process()
    installProc.executableURL = URL(fileURLWithPath: "/usr/local/bin/pwsh")
    installProc.arguments = ["-NoProfile", "-Command", "Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber"]
    installProc.standardOutput = FileHandle.nullDevice
    installProc.standardError = FileHandle.nullDevice
    do {
        try installProc.run()
        installProc.waitUntilExit()
        return installProc.terminationStatus == 0
            ? (true, "Microsoft.Graph module installed")
            : (false, "Failed to install Microsoft.Graph module")
    } catch {
        return (false, "Failed to install module: \(error)")
    }
}

func startPowerShellSession(modulePath: String) -> Process? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/pwsh")
    proc.arguments = ["-NoExit", "-NoProfile", "-Command", "-"]
    proc.standardInput = Pipe()
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do {
        try proc.run()
        // Import the module
        let importCmd = "Import-Module '\(modulePath)'; Write-Host '---READY---'\n"
        (proc.standardInput as? Pipe)?.fileHandleForWriting.write(importCmd.data(using: .utf8)!)
        return proc
    } catch {
        return nil
    }
}

func runPSCommand(_ process: Process, command: String, timeout: TimeInterval = 30) -> [String] {
    guard let stdin = process.standardInput as? Pipe,
          let stdout = process.standardOutput as? Pipe else { return [] }
    let marker = "---COMMAND-COMPLETE---"
    let fullCmd = "\(command); Write-Host '\(marker)'\n"
    stdin.fileHandleForWriting.write(fullCmd.data(using: .utf8)!)

    var lines: [String] = []
    let startTime = Date()
    let handle = stdout.fileHandleForReading

    while Date().timeIntervalSince(startTime) < timeout {
        if let data = handle.availableData as Data?, !data.isEmpty,
           let str = String(data: data, encoding: .utf8) {
            for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.contains(marker) { return lines }
                if !cleaned.isEmpty { lines.append(cleanANSI(cleaned)) }
            }
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    return lines
}

func cleanANSI(_ str: String) -> String {
    str.replacingOccurrences(of: "\\x1b[^m]*m|\\x1b\\x1b", with: "", options: .regularExpression)
}
```

**Step 3: Add HTTP server for Intune endpoints**

Add a long-lived NWListener-based HTTP server that routes requests. Add after the PowerShell helpers:

```swift
// MARK: - Intune HTTP server

var intuneState = IntuneState()
let intuneQueue = DispatchQueue(label: "intune-server")
let stateQueue = DispatchQueue(label: "intune-state") // serial queue for thread safety

func parseHTTPRequest(_ data: Data) -> (method: String, path: String, body: Data?) {
    guard let str = String(data: data, encoding: .utf8) else { return ("", "", nil) }
    let lines = str.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let firstLine = lines.first else { return ("", "", nil) }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else { return ("", "", nil) }
    let method = String(parts[0])
    let path = String(parts[1])
    // Find body after empty line
    if let emptyIdx = lines.firstIndex(where: { $0.isEmpty }), emptyIdx + 1 < lines.count {
        let bodyStr = lines[(emptyIdx + 1)...].joined(separator: "\r\n")
        return (method, path, bodyStr.data(using: .utf8))
    }
    return (method, path, nil)
}

func jsonResponse(_ body: Data, status: Int = 200) -> Data {
    let statusText = status == 200 ? "OK" : "Bad Request"
    let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
    return header.data(using: .utf8)! + body
}

func handleIntuneRequest(method: String, path: String, body: Data?) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    // CORS preflight
    if method == "OPTIONS" {
        return "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n".data(using: .utf8)!
    }

    switch path {
    case "/status":
        let resp = stateQueue.sync { intuneState.statusResponse }
        guard let data = try? encoder.encode(resp) else { return jsonResponse("{}".data(using: .utf8)!) }
        return jsonResponse(data)

    case "/connect":
        return handleConnect(encoder: encoder)

    case "/prerequisites":
        return handlePrerequisites(body: body, encoder: encoder)

    case "/upload":
        return handleUpload(body: body, encoder: encoder)

    case "/upload-file":
        return handleFileUpload(body: body, encoder: encoder)

    case "/progress":
        let resp = stateQueue.sync { intuneState.statusResponse }
        guard let data = try? encoder.encode(resp) else { return jsonResponse("{}".data(using: .utf8)!) }
        return jsonResponse(data)

    case "/disconnect":
        return handleDisconnect(encoder: encoder)

    default:
        let err = ["error": "Not found"]
        let data = (try? encoder.encode(err)) ?? "{}".data(using: .utf8)!
        return jsonResponse(data, status: 400)
    }
}

func startIntuneServer() {
    guard let port = NWEndpoint.Port(rawValue: intunePort),
          let listener = try? NWListener(using: .tcp, on: port) else { return }

    listener.newConnectionHandler = { conn in
        conn.start(queue: intuneQueue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data = data else { conn.cancel(); return }
            let (method, path, body) = parseHTTPRequest(data)
            let response = handleIntuneRequest(method: method, path: path, body: body)
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
    listener.start(queue: intuneQueue)
}
```

**Step 4: Implement /connect handler**

```swift
func handleConnect(encoder: JSONEncoder) -> Data {
    stateQueue.sync { intuneState.operation = .connecting }

    DispatchQueue.global(qos: .userInitiated).async {
        // Step 1: Install deps
        stateQueue.sync {
            intuneState.items = [ProgressItem(name: "Getting things ready...", status: .processing)]
        }

        let pwshResult = installPowerShellIfNeeded()
        if !pwshResult.success {
            stateQueue.sync {
                intuneState.items = [ProgressItem(name: "Getting things ready...", status: .fail, message: pwshResult.message)]
                intuneState.operation = .idle
            }
            return
        }

        let moduleResult = installGraphModuleIfNeeded()
        if !moduleResult.success {
            stateQueue.sync {
                intuneState.items = [ProgressItem(name: "Installing dependencies...", status: .fail, message: moduleResult.message)]
                intuneState.operation = .idle
            }
            return
        }

        stateQueue.sync {
            intuneState.items = [ProgressItem(name: "Getting things ready...", status: .success)]
        }

        // Step 2: Find module and start PS session
        guard let modPath = findModulePath() else {
            stateQueue.sync {
                intuneState.items.append(ProgressItem(name: "Loading modules...", status: .fail, message: "IntuneBaseBuild.psm1 not found"))
                intuneState.operation = .idle
            }
            return
        }

        guard let ps = startPowerShellSession(modulePath: modPath) else {
            stateQueue.sync {
                intuneState.items.append(ProgressItem(name: "Starting session...", status: .fail, message: "Could not start PowerShell"))
                intuneState.operation = .idle
            }
            return
        }

        stateQueue.sync {
            intuneState.psProcess = ps
            intuneState.modulePath = modPath
            intuneState.items.append(ProgressItem(name: "Connecting to Microsoft Graph...", status: .processing))
        }

        // Step 3: Connect to Graph
        let connectOutput = runPSCommand(ps, command: "Connect-IntuneGraph", timeout: 120)

        // Extract tenant ID
        let tenantId = connectOutput.first(where: { $0.count > 10 && !$0.contains(" ") })

        if let tid = tenantId {
            // Get org name
            let orgOutput = runPSCommand(ps, command: "(Get-MgOrganization).DisplayName", timeout: 30)
            let orgName = orgOutput.first?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Get user email
            let userOutput = runPSCommand(ps, command: "(Get-MgContext).Account", timeout: 10)
            let userEmail = userOutput.first?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract bearer token
            let tokenOutput = runPSCommand(ps, command: "$r = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/me' -OutputType HttpResponseMessage; $r.RequestMessage.Headers.Authorization.Parameter", timeout: 15)
            // Token stored internally if needed; main use is PowerShell cmdlets

            stateQueue.sync {
                intuneState.connected = true
                intuneState.tenantId = tid
                intuneState.tenantName = orgName
                intuneState.userEmail = userEmail
                intuneState.items = [
                    ProgressItem(name: "Getting things ready...", status: .success),
                    ProgressItem(name: "Connecting to Microsoft Graph...", status: .success)
                ]
                intuneState.operation = .idle
            }
        } else {
            stateQueue.sync {
                intuneState.items = [
                    ProgressItem(name: "Getting things ready...", status: .success),
                    ProgressItem(name: "Connecting to Microsoft Graph...", status: .fail, message: "Failed to connect")
                ]
                intuneState.operation = .idle
            }
        }
    }

    let resp = ["status": "connecting"]
    let data = (try? encoder.encode(resp)) ?? "{}".data(using: .utf8)!
    return jsonResponse(data)
}
```

**Step 5: Implement /prerequisites handler**

```swift
struct PrereqRequest: Decodable {
    let skip: Bool?
}

func handlePrerequisites(body: Data?, encoder: JSONEncoder) -> Data {
    guard stateQueue.sync(execute: { intuneState.connected }),
          let ps = stateQueue.sync(execute: { intuneState.psProcess }) else {
        let err = ["error": "Not connected"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }

    stateQueue.sync { intuneState.operation = .prerequisites }

    DispatchQueue.global(qos: .userInitiated).async {
        let prereqItems = [
            "APNs Certificate", "ABM Token", "VPP Token",
            "Test Group", "User Assignment", "FileVault", "Enrollment Profile"
        ]

        stateQueue.sync {
            intuneState.items = prereqItems.map { ProgressItem(name: $0, status: .pending) }
        }

        func updateItem(_ name: String, status: ItemStatus, message: String? = nil) {
            stateQueue.sync {
                if let idx = intuneState.items.firstIndex(where: { $0.name == name }) {
                    intuneState.items[idx].status = status
                    intuneState.items[idx].message = message
                }
            }
        }

        // APNs
        updateItem("APNs Certificate", status: .processing)
        let apns = runPSCommand(ps, command: "Get-MgBetaDeviceManagementApplePushNotificationCertificate | Select-Object -ExpandProperty ExpirationDateTime | Get-Date -Format 'yyyy-MM-dd'", timeout: 30)
        updateItem("APNs Certificate", status: apns.isEmpty ? .fail : .success, message: apns.first)

        // ABM
        updateItem("ABM Token", status: .processing)
        let abm = runPSCommand(ps, command: "Get-MgBetaDeviceManagementDepOnboardingSetting | Select-Object -ExpandProperty TokenExpirationDateTime | Get-Date -Format 'yyyy-MM-dd'", timeout: 30)
        updateItem("ABM Token", status: abm.isEmpty ? .fail : .success, message: abm.first)

        // VPP
        updateItem("VPP Token", status: .processing)
        let vpp = runPSCommand(ps, command: "Get-MgDeviceAppManagementVppToken | Select-Object -ExpandProperty ExpirationDateTime | Get-Date -Format 'yyyy-MM-dd'", timeout: 30)
        updateItem("VPP Token", status: vpp.isEmpty ? .fail : .success, message: vpp.first)

        // Test Group
        updateItem("Test Group", status: .processing)
        let groupOutput = runPSCommand(ps, command: "New-IntuneStaticGroup -DisplayName 'iStore Business PoC Group'", timeout: 30)
        var groupId: String?
        for line in groupOutput {
            if line.contains("Id:") || line.contains("id:") {
                groupId = line.split(separator: ":").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if line.count > 30 && !line.contains(" ") {
                groupId = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let gid = groupId {
            stateQueue.sync { intuneState.groupId = gid }
            updateItem("Test Group", status: .success, message: gid)

            // User Assignment
            updateItem("User Assignment", status: .processing)
            let assignOutput = runPSCommand(ps, command: "Assign-CurrentUserToGroup -GroupId '\(gid)'", timeout: 30)
            let assignSuccess = assignOutput.contains(where: { $0.contains("Successfully") || $0.contains("already") })
            updateItem("User Assignment", status: assignSuccess ? .success : .fail)

            // FileVault
            updateItem("FileVault", status: .processing)
            let fvOutput = runPSCommand(ps, command: "New-FileVault -GroupId '\(gid)'", timeout: 60)
            let fvSuccess = fvOutput.contains(where: { $0.contains("SUCCESS") })
            updateItem("FileVault", status: fvSuccess ? .success : .fail)

            // Enrollment Profile
            updateItem("Enrollment Profile", status: .processing)
            let epOutput = runPSCommand(ps, command: "New-EnrollmentProfile", timeout: 30)
            let epSuccess = epOutput.contains(where: { $0.contains("successfully") || $0.contains("SUCCESS") || $0.contains("already exists") })
            updateItem("Enrollment Profile", status: epSuccess ? .success : .fail)
        } else {
            updateItem("Test Group", status: .fail, message: "Could not extract group ID")
            updateItem("User Assignment", status: .fail, message: "No group")
            updateItem("FileVault", status: .fail, message: "No group")
            updateItem("Enrollment Profile", status: .processing)
            let epOutput = runPSCommand(ps, command: "New-EnrollmentProfile", timeout: 30)
            let epSuccess = epOutput.contains(where: { $0.contains("successfully") || $0.contains("SUCCESS") || $0.contains("already exists") })
            updateItem("Enrollment Profile", status: epSuccess ? .success : .fail)
        }

        stateQueue.sync { intuneState.operation = .idle }
    }

    let resp = ["status": "running"]
    return jsonResponse((try? encoder.encode(resp)) ?? Data())
}
```

**Step 6: Implement /upload handler**

```swift
struct UploadRequest: Decodable {
    struct FileItem: Decodable {
        let name: String
        let url: String?       // S3 URL for remote files
        let localPath: String? // Path for user-uploaded files
        let type: String       // sh, mobileconfig, ios_mobileconfig, json, cash, pkg
    }
    let files: [FileItem]
    let groupId: String?
}

func handleUpload(body: Data?, encoder: JSONEncoder) -> Data {
    guard stateQueue.sync(execute: { intuneState.connected }),
          let ps = stateQueue.sync(execute: { intuneState.psProcess }),
          let body = body,
          let request = try? JSONDecoder().decode(UploadRequest.self, from: body) else {
        let err = ["error": "Not connected or invalid request"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }

    let groupId = request.groupId ?? stateQueue.sync(execute: { intuneState.groupId }) ?? ""
    let tenantId = stateQueue.sync(execute: { intuneState.tenantId }) ?? ""
    let tenantName = stateQueue.sync(execute: { intuneState.tenantName }) ?? ""

    stateQueue.sync { intuneState.operation = .uploading }

    DispatchQueue.global(qos: .userInitiated).async {
        stateQueue.sync {
            intuneState.items = request.files.map { ProgressItem(name: $0.name, status: .pending) }
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("intune-basebuild-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        func updateItem(_ name: String, status: ItemStatus, message: String? = nil) {
            stateQueue.sync {
                if let idx = intuneState.items.firstIndex(where: { $0.name == name }) {
                    intuneState.items[idx].status = status
                    intuneState.items[idx].message = message
                }
            }
        }

        for file in request.files {
            updateItem(file.name, status: .processing)

            // Get file to local path
            var localPath: String
            if let lp = file.localPath {
                localPath = lp
            } else if let urlStr = file.url, let url = URL(string: urlStr) {
                let dest = (tmpDir as NSString).appendingPathComponent(file.name)
                do {
                    let data = try Data(contentsOf: url)
                    try data.write(to: URL(fileURLWithPath: dest))
                    localPath = dest
                } catch {
                    updateItem(file.name, status: .fail, message: "Download failed: \(error.localizedDescription)")
                    continue
                }
            } else {
                updateItem(file.name, status: .fail, message: "No file source")
                continue
            }

            // Apply dynamic replacements
            if let content = try? String(contentsOfFile: localPath, encoding: .utf8) {
                var modified = content
                if !tenantId.isEmpty {
                    modified = modified.replacingOccurrences(of: "{tenant_id}", with: tenantId)
                }
                if !tenantName.isEmpty {
                    modified = modified.replacingOccurrences(of: "{org_name}", with: tenantName)
                }
                if modified != content {
                    try? modified.write(toFile: localPath, atomically: true, encoding: .utf8)
                }
            }

            // Build PowerShell command based on type
            let escapedPath = localPath.replacingOccurrences(of: "'", with: "''")
            var command: String
            var timeout: TimeInterval = 60

            switch file.type {
            case "sh":
                command = "New-SingleShellScript -FilePath '\(escapedPath)' -GroupId '\(groupId)'"
            case "mobileconfig":
                command = "New-SingleMobileConfig -FilePath '\(escapedPath)' -GroupId '\(groupId)'"
            case "ios_mobileconfig":
                command = "New-SingleiOSMobileConfig -FilePath '\(escapedPath)' -GroupId '\(groupId)'"
            case "json":
                command = "New-SingleJSON -FilePath '\(escapedPath)' -GroupId '\(groupId)'"
            case "cash":
                command = "New-SingleCustomAttributeScript -FilePath '\(escapedPath)' -GroupId '\(groupId)'"
            case "pkg":
                // For PKG, we need package ID and version — extract via pkgutil
                let pkgId = extractPackageId(path: localPath)
                command = "New-SinglePKG -FilePath '\(escapedPath)' -PackageId '\(pkgId.id)' -PackageVersion '\(pkgId.version)' -GroupId '\(groupId)'"
                timeout = 300
            default:
                updateItem(file.name, status: .fail, message: "Unknown file type: \(file.type)")
                continue
            }

            let output = runPSCommand(ps, command: command, timeout: timeout)
            let hasError = output.contains(where: { $0.lowercased().contains("error") || $0.lowercased().contains("failed") })
            updateItem(file.name, status: hasError ? .fail : .success, message: output.last)
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: tmpDir)
        stateQueue.sync { intuneState.operation = .idle }
    }

    let resp = ["status": "uploading"]
    return jsonResponse((try? encoder.encode(resp)) ?? Data())
}

func extractPackageId(path: String) -> (id: String, version: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    proc.arguments = ["--expand", path, "/tmp/pkg-expand-\(UUID().uuidString)"]
    let expandDir = proc.arguments![1]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        // Look for PackageInfo
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: expandDir) {
            while let file = enumerator.nextObject() as? String {
                if file.hasSuffix("PackageInfo") {
                    let fullPath = (expandDir as NSString).appendingPathComponent(file)
                    if let data = fm.contents(atPath: fullPath),
                       let str = String(data: data, encoding: .utf8) {
                        // Parse identifier and version from XML
                        var pkgId = "", version = ""
                        if let idRange = str.range(of: "identifier=\""),
                           let idEnd = str.range(of: "\"", range: idRange.upperBound..<str.endIndex) {
                            pkgId = String(str[idRange.upperBound..<idEnd.lowerBound])
                        }
                        if let verRange = str.range(of: "version=\""),
                           let verEnd = str.range(of: "\"", range: verRange.upperBound..<str.endIndex) {
                            version = String(str[verRange.upperBound..<verEnd.lowerBound])
                        }
                        if !pkgId.isEmpty && !pkgId.hasSuffix(".payload.pkg") {
                            try? fm.removeItem(atPath: expandDir)
                            return (pkgId, version)
                        }
                    }
                }
            }
        }
        try? fm.removeItem(atPath: expandDir)
    } catch {}
    return ("unknown", "1.0")
}
```

**Step 7: Implement /upload-file and /disconnect handlers**

```swift
func handleFileUpload(body: Data?, encoder: JSONEncoder) -> Data {
    // Multipart file upload — save to tmp and return path
    // For simplicity, accept raw file body with filename in query/header
    guard let body = body else {
        let err = ["error": "No file data"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("intune-uploads").path
    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

    // Extract filename from body prefix (first line is filename, rest is content)
    // Alternatively, the web app can send JSON with base64-encoded content
    struct FileUploadRequest: Decodable {
        let name: String
        let content: String // base64
    }

    guard let req = try? JSONDecoder().decode(FileUploadRequest.self, from: body) else {
        let err = ["error": "Invalid upload format"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }

    guard let fileData = Data(base64Encoded: req.content) else {
        let err = ["error": "Invalid base64 content"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }

    let destPath = (tmpDir as NSString).appendingPathComponent(req.name)
    do {
        try fileData.write(to: URL(fileURLWithPath: destPath))
        let resp = ["path": destPath, "name": req.name]
        return jsonResponse((try? encoder.encode(resp)) ?? Data())
    } catch {
        let err = ["error": "Failed to save file"]
        return jsonResponse((try? encoder.encode(err)) ?? Data(), status: 400)
    }
}

func handleDisconnect(encoder: JSONEncoder) -> Data {
    if let ps = stateQueue.sync(execute: { intuneState.psProcess }) {
        let _ = runPSCommand(ps, command: "Disconnect-MgGraph", timeout: 10)
        ps.terminate()
    }
    stateQueue.sync {
        intuneState = IntuneState()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        NSApp.terminate(nil)
    }
    let resp = ["status": "disconnected"]
    return jsonResponse((try? encoder.encode(resp)) ?? Data())
}
```

**Step 8: Update AppDelegate to handle intune-base-build URL**

In the existing `application(_:open:)` method, add a new branch before the `guard host == "fetch-tcc"` line:

```swift
// Intune Base Build — long-lived mode
if host == "intune-base-build" {
    handledURL = true
    startIntuneServer()
    return
}
```

**Step 9: Commit**

```bash
git add agent/Sources/MacAdminToolbox/main.swift
git commit -m "feat: add Intune Base Build HTTP server to Swift agent"
```

---

### Task 3: Register route and dashboard card for Intune Base Build

**Files:**
- Modify: `app/views/main.py`
- Modify: `app/templates/dashboard.html`

**Step 1: Add tool name to routes**

In `app/views/main.py`, add `"intune_base_build"` to the `TOOL_NAMES` set:

```python
TOOL_NAMES = {
    "equitrac",
    "netskope",
    "santa",
    "swiftsetup",
    "smartbranding",
    "bookmarks",
    "fusion",
    "patchy",
    "compliance_fixer",
    "auto_configurator",
    "sentinelone_token",
    "intune_base_build",
}
```

Also add a macOS check like `auto_configurator` since it requires the local agent. Update the `toolbox` function:

```python
@main.route("/<tool_name>")
@login_required
def toolbox(tool_name):
    if tool_name not in TOOL_NAMES:
        abort(404)
    if tool_name in ("auto_configurator", "intune_base_build") and not _is_mac_user_agent():
        abort(404)
    return render_template(f"tools/{tool_name}.html")
```

**Step 2: Add dashboard card**

In `app/templates/dashboard.html`, add the Intune Base Build card inside the `{% if show_auto_config %}` block (since it also requires macOS), or create a separate conditional. Add it in the Platform Tools section, before the `{% if show_auto_config %}` block:

```html
{% if show_auto_config %}
<a href="{{ url_for('main.toolbox', tool_name='intune_base_build') }}" class="tool-card">
  <div class="tool-card-left">
    <div class="tool-card-title">Intune Base Build</div>
    <div class="tool-card-desc">Deploy shell scripts, configuration profiles, and policies to a client Intune tenant.</div>
  </div>
  <span class="btn btn-primary">Open →</span>
</a>
{% endif %}
```

**Step 3: Commit**

```bash
git add app/views/main.py app/templates/dashboard.html
git commit -m "feat: add Intune Base Build route and dashboard card"
```

---

### Task 4: Create the Intune Base Build wizard UI

**Files:**
- Create: `app/templates/tools/intune_base_build.html`

**Step 1: Create the template**

Create `app/templates/tools/intune_base_build.html` with the 4-step wizard. The template extends `base.html` and includes `_shared_utils.html`. Follow the existing tool patterns (dark theme, same CSS classes).

The wizard has 4 steps, each in a `.card` container. Only the active step is shown. Steps unlock sequentially.

Key UI elements per step:

**Step 1 (Connect):**
- Companion app section (collapsible, same pattern as auto_configurator)
- "Connect to Intune" button that opens `macadmin-toolbox://intune-base-build`
- Status area showing progress items (getting ready, connecting)
- On success: displays tenant name + user email
- "Next" button (enabled after connect)

**Step 2 (Prerequisites):**
- "Run prerequisite checks" toggle (enabled by default)
- "Skip" button
- Checklist: APNs, ABM, VPP, Test Group, User Assignment, FileVault, Enrollment Profile
- Each with status icon (pending/processing/success/fail)
- "Next" button (enabled after all complete or skip)

**Step 3 (Select Files):**
- "Load file list" button (fetches from S3 file_list.txt)
- Checklist of files with checkboxes
- Select all / Deselect all
- Drop zone for custom file uploads
- Uploaded files appear in list with checkboxes
- "Next" button (enabled when at least 1 file selected)

**Step 4 (Upload):**
- Summary count of selected files
- "Upload to Intune" button
- Per-file status icons + progress
- Log area at bottom

The JavaScript polls `http://127.0.0.1:8765/progress` at 1-second intervals during active operations. It calls `http://127.0.0.1:8765/connect`, `/prerequisites`, `/upload` etc. directly from the browser (CORS enabled by the agent).

The full HTML/JS for this file is large (~800-1000 lines). Follow patterns from `equitrac.html` for card layout, `auto_configurator.html` for agent polling, and `netskope.html` for the wizard-like flow.

Core JavaScript functions:

```javascript
var INTUNE_PORT = 8765;
var currentStep = 1;
var uploadedFiles = []; // {name, localPath, type}

function intuneRequest(method, path, body) {
  var opts = { method: method, mode: 'cors', headers: {'Content-Type': 'application/json'} };
  if (body) opts.body = JSON.stringify(body);
  return fetch('http://127.0.0.1:' + INTUNE_PORT + path, opts).then(function(r) { return r.json(); });
}

// Step 1: Connect
function intuneConnect() {
  window.open('macadmin-toolbox://intune-base-build', '_blank');
  startPollingConnect();
}

function startPollingConnect() {
  var poll = setInterval(function() {
    intuneRequest('GET', '/status').then(function(data) {
      updateConnectUI(data);
      if (data.connected) {
        clearInterval(poll);
        unlockStep(2);
      }
    }).catch(function() { /* agent not ready yet */ });
  }, 1500);
}

// Step 2: Prerequisites
function runPrerequisites() {
  intuneRequest('POST', '/prerequisites', {});
  startPollingProgress('prerequisites', function() { unlockStep(3); });
}

function skipPrerequisites() { unlockStep(3); }

// Step 3: File selection
function loadFileList() {
  fetch('https://narcp.s3.af-south-1.amazonaws.com/BaseBuildFiles/file_list.txt')
    .then(function(r) { return r.text(); })
    .then(function(text) { renderFileList(text.trim().split('\n')); });
}

function uploadCustomFile(file) {
  var reader = new FileReader();
  reader.onload = function() {
    var b64 = btoa(String.fromCharCode.apply(null, new Uint8Array(reader.result)));
    intuneRequest('POST', '/upload-file', { name: file.name, content: b64 })
      .then(function(resp) {
        uploadedFiles.push({ name: resp.name, localPath: resp.path, type: detectFileType(file.name) });
        renderUploadedFile(resp.name);
      });
  };
  reader.readAsArrayBuffer(file);
}

// Step 4: Upload
function startUpload() {
  var selected = getSelectedFiles(); // [{name, url?, localPath?, type}]
  intuneRequest('POST', '/upload', { files: selected, groupId: null });
  startPollingProgress('upload', function() { /* done */ });
}

function startPollingProgress(expectedOp, onComplete) {
  var poll = setInterval(function() {
    intuneRequest('GET', '/progress').then(function(data) {
      updateProgressUI(data);
      if (data.operation === 'idle' && data.items.length > 0) {
        clearInterval(poll);
        if (onComplete) onComplete();
      }
    });
  }, 1000);
}

function detectFileType(name) {
  if (name.startsWith('ios_') && name.endsWith('.mobileconfig')) return 'ios_mobileconfig';
  if (name.endsWith('.mobileconfig')) return 'mobileconfig';
  if (name.endsWith('.sh')) return 'sh';
  if (name.endsWith('.json')) return 'json';
  if (name.endsWith('.cash')) return 'cash';
  if (name.endsWith('.pkg')) return 'pkg';
  return 'unknown';
}

// Wizard navigation
function unlockStep(n) {
  currentStep = n;
  // Show/hide step containers, update step indicators
}

function goToStep(n) {
  if (n <= currentStep) { /* allow going back */ }
}
```

**Step 2: Commit**

```bash
git add app/templates/tools/intune_base_build.html
git commit -m "feat: add Intune Base Build wizard UI"
```

---

### Task 5: Integration test — end-to-end manual verification

**Step 1: Build the agent**

```bash
cd agent && swift build -c release
```

**Step 2: Verify URL scheme launches agent**

Open `macadmin-toolbox://intune-base-build` in Safari. Verify the agent starts and `/status` returns on `http://127.0.0.1:8765/status`.

**Step 3: Run the web app**

```bash
python run.py
```

Navigate to the Intune Base Build tool. Verify:
- Step 1: Connect button launches agent, polls for status, shows tenant info
- Step 2: Prerequisites run and show status per item (or skip works)
- Step 3: File list loads from S3, checkboxes work, custom upload works
- Step 4: Upload processes files with real-time progress

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration fixes for Intune Base Build"
```

---

## Task Dependency Order

```
Task 1 (bundle psm1) → Task 2 (agent HTTP server) → Task 3 (route + dashboard) → Task 4 (wizard UI) → Task 5 (integration test)
```

All tasks are sequential — each builds on the previous.

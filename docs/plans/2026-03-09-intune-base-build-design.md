# Intune Base Build — Design Document

## Overview

Add an Intune Base Build tool to the Online MacAdmin Toolbox. The tool automates deployment of configuration files (shell scripts, mobileconfigs, JSON policies, custom attributes, PKGs) to a client's Microsoft Intune tenant.

## Architecture

Two components working together:

### Swift Agent (updated existing agent)

The existing Mac Admin Toolbox agent gains a long-lived HTTP server mode for Intune operations. The existing TCC one-shot pattern is unchanged.

Responsibilities:
- Silent installation of PowerShell 7+ and Microsoft.Graph modules if missing ("Getting things ready...")
- `Connect-MgGraph` with all scopes upfront, extract Bearer token
- Auto-detect tenant ID and org name via `GET /organization`
- Run prerequisite checks via PowerShell cmdlets
- Download files from S3, apply dynamic replacements, upload via PowerShell cmdlets
- Accept user-uploaded files and upload via PowerShell cmdlets

### Web UI (Flask + JS)

A new tool page with a 4-step wizard. The web app is purely UI orchestration — all Graph API interaction goes through the agent.

## Authentication

The agent uses PowerShell's `Connect-MgGraph` which leverages Microsoft's first-party app ("Microsoft Graph Command Line Tools"). This provides frictionless authentication for client tenants without needing a custom multi-tenant app registration.

Token extraction:
```powershell
Connect-MgGraph -NoWelcome -Scopes 'DeviceManagementApps.ReadWrite.All','DeviceManagementConfiguration.ReadWrite.All','DeviceManagementServiceConfig.ReadWrite.All','Group.ReadWrite.All','User.Read.All','Organization.Read.All'
$response = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/me" -OutputType HttpResponseMessage
$token = $response.RequestMessage.Headers.Authorization.Parameter
```

## Agent HTTP Protocol

URL scheme: `macadmin-toolbox://intune-base-build`

Agent stays alive for the session duration. HTTP API on port 8765:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/status` | GET | Health check + current state |
| `/connect` | GET | Trigger Connect-MgGraph, return token + tenant info |
| `/prerequisites` | POST | Run all prerequisite checks |
| `/upload` | POST | Accept file list (S3 URLs + types), download and upload |
| `/upload-file` | POST | Accept user-uploaded file (multipart) |
| `/progress` | GET | Poll for current operation progress |
| `/disconnect` | POST | Disconnect-MgGraph, terminate agent |

### Progress Model

Browser polls `GET /progress`. Agent returns:
```json
{
  "operation": "upload",
  "items": [
    {"name": "wifi.mobileconfig", "status": "success"},
    {"name": "filevault.json", "status": "processing"},
    {"name": "compliance.sh", "status": "pending"}
  ]
}
```

## Wizard Steps

### Step 1: Connect
- "Connect to Intune" button triggers `macadmin-toolbox://intune-base-build`
- Agent installs dependencies silently if needed
- User authenticates via device code flow in terminal
- Browser polls agent, receives token + tenant name + user info
- Displays tenant name and connected user
- Step completes, next step unlocks

### Step 2: Prerequisites (optional, skippable)
- Toggle to enable/skip
- If enabled, agent runs via PowerShell:
  - APNs certificate expiration check
  - ABM token expiration check
  - VPP token expiration check
  - Create test group ("iStore Business PoC Group") + assign current user
  - Create FileVault policy
  - Create enrollment profile
- Each item shows status icons (pending -> processing -> success/fail)
- "Skip" button available

### Step 3: Select Files
- File list fetched from S3 (`file_list.txt`) with checkboxes
- Select all / deselect all controls
- Drop zone / file picker for custom file uploads
- Uploaded files appear in the same checklist
- Note: dynamic replacements (`{tenant_id}`, org name) applied automatically

### Step 4: Upload
- Summary of selected files
- "Upload to Intune" button
- Agent processes each file:
  1. Download from S3 (or use uploaded file)
  2. Apply dynamic replacements
  3. Upload via appropriate PowerShell cmdlet
- Real-time per-file status icons + log output

## File Type Handling

| Extension | PowerShell Command |
|-----------|--------------------|
| `.sh` | `New-SingleShellScript` |
| `.mobileconfig` | `New-SingleMobileConfig` |
| `ios_*.mobileconfig` | `New-SingleiOSMobileConfig` |
| `.json` | `New-SingleJSON` |
| `.cash` | `New-SingleCustomAttributeScript` |
| `.pkg` | `New-SinglePKG` |

## Dynamic Replacements

Applied automatically before upload:
- `{tenant_id}` replaced with actual tenant ID (from Graph API)
- Organization name injected into SSO configuration files

Both values auto-detected from `GET /organization` after connecting.

## PowerShell Dependencies

Installed silently by agent if missing:
- PowerShell 7+ (`/usr/local/bin/pwsh`)
- `Microsoft.Graph.Authentication`
- Additional modules as needed for check cmdlets (`Microsoft.Graph.Beta.DeviceManagement`, etc.)

## Graph API Scopes

All requested upfront in single consent prompt:
- `DeviceManagementApps.ReadWrite.All`
- `DeviceManagementConfiguration.ReadWrite.All`
- `DeviceManagementServiceConfig.ReadWrite.All`
- `Group.ReadWrite.All`
- `User.Read.All`
- `Organization.Read.All`

## Scope / Out of Scope

**In scope (v1):**
- Flat file uploads (all types including PKG)
- Dynamic replacements
- Optional prerequisite checks
- S3 file list + custom file upload
- Silent dependency installation

**Out of scope (v2):**
- Subdirectory handling (PKG + pre/post install scripts)
- Token refresh (session expected to complete within token lifetime)

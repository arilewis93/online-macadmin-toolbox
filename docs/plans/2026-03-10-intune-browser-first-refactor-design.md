# Intune Base Build: Browser-First Refactor

**Date:** 2026-03-10
**Status:** Approved

## Problem

The current Intune Base Build feature pushes all work to the Swift agent + PowerShell, requiring 10+ Microsoft.Graph modules installed locally. The agent handles auth, prerequisite checks, file uploads, config creation, group management, assignments, and .pkg encryption/upload. This is heavyweight and fragile.

## Goal

Minimize the agent to an auth-only broker. Move all Intune operations to browser JavaScript, leveraging extracted Intune portal source code from Cowork.

## Architecture

```
Browser (intune_base_build.html)
├── pkgparser-REAL.js        → XAR parsing, plist reading, bundle ID extraction
├── Intune Encrypt+Upload    → AES-CBC encryption, chunked Azure blob upload
├── Graph API Client         → fetch() + token for all Graph REST calls
│   ├── Prerequisites        → APNs, ABM, VPP checks
│   ├── Configs              → mobileconfig, settings catalog, shell scripts
│   ├── Groups               → create, add members
│   ├── Assignments          → app, config, script assignments
│   └── App Upload           → create app, content version, content file, commit
└── GET /token ──────────────→ Agent (127.0.0.1:8765)

Agent (Swift + PowerShell)
├── POST /connect            → Connect-MgGraph (interactive browser login)
├── GET  /status             → Connection state, tenant info
├── GET  /token              → Extract and return current Graph access token
├── POST /disconnect         → Disconnect-MgGraph
└── Module: Microsoft.Graph.Authentication (ONLY)
```

## Key Decisions

1. **Auth stays in agent** - MSP model requires authenticating into different client tenants. PowerShell's `Connect-MgGraph` handles this well. MSAL.js would require app registration per client tenant.

2. **Agent exposes `/token` endpoint** - Browser requests a fresh token before operations. Agent ensures validity. Future-proof for longer processes.

3. **Browser does pkg parsing** - Using `pkgparser-REAL.js` (Intune's own webpack bundle) which includes XAR parser, pako inflate, binary plist parser, and `pkgparse()` entry point.

4. **Browser does encryption + upload** - Using extracted `Encrypt-Upload-Commit.js` which has AES-CBC encryption class and `AsyncIntuneAppFileUploader` with chunked Azure blob upload.

5. **Only 1 PowerShell module** - `Microsoft.Graph.Authentication` replaces the current 10+ modules.

## Extracted Intune JS Files (from Cowork)

| File | Purpose | Size |
|------|---------|------|
| `BZ7Vuy4PV5pR-IntuneAppFileUpload-orchestrator.js` | Upload orchestration, RPC endpoint definitions | 4KB |
| `vTbU1h-51IZv-FileUpload-BlockBlob.js` | Azure block blob upload, file reader, progress tracking | 39KB |
| `GOdg3ZqF15tj-Encrypt-Upload-Commit.js` | AES-CBC encryption, Intune app uploader, commit flow | 23KB |
| `Rk5Zr_wzls2b-IntuneZipFileHelper.js` | Zip/archive reader helpers | 1.5KB |
| `pkgparser-REAL.js` | Full pkg parser: XAR, pako, plist, bundle ID extraction | 252KB |
| `NgXJAz2UaHm1-inflate-binary.js` | Azure Portal framework + zip library (may not be needed) | large |
| `P7OFN2tJl76C-xar-parser.js` | Viva Controls UI widgets (not needed) | large |

## Graph API Endpoints (Browser JS will call directly)

### PKG Upload Flow
| Step | Endpoint | Method |
|------|----------|--------|
| Create app | `/beta/deviceAppManagement/mobileApps` | POST |
| Create content version | `/beta/.../macOSPkgApp/contentVersions` | POST |
| Create content file | `/beta/.../contentVersions/{id}/files` | POST |
| Poll for SAS URI | `/beta/.../files/{id}` | GET |
| Upload blocks | SAS URI + `&comp=block&blockid=` | PUT |
| Commit block list | SAS URI + `&comp=blocklist` | PUT |
| Commit file | `/beta/.../files/{id}/commit` | POST |
| Patch app | `/beta/deviceAppManagement/mobileApps/{id}` | PATCH |

### Simple Operations
| Operation | Endpoint | Method |
|-----------|----------|--------|
| Create mobileconfig | `/beta/deviceManagement/deviceConfigurations` | POST |
| Create settings catalog | `/beta/deviceManagement/configurationPolicies` | POST |
| Create shell script | `/beta/deviceManagement/deviceShellScripts` | POST |
| Create custom attribute | `/beta/deviceManagement/deviceCustomAttributeShellScripts` | POST |
| Create group | `/v1.0/groups` | POST |
| Add group member | `/v1.0/groups/{id}/members/$ref` | POST |
| Check APNs | `/beta/deviceManagement/applePushNotificationCertificate` | GET |
| Check ABM | `/beta/deviceManagement/depOnboardingSettings` | GET |
| Check VPP | `/v1.0/deviceAppManagement/vppTokens` | GET |
| Create enrollment profile | `/beta/.../depOnboardingSettings/{id}/enrollmentProfiles` | POST |
| Assign app | `/beta/deviceAppManagement/mobileApps/{id}/assign` | POST |
| Assign config | `/beta/deviceManagement/deviceConfigurations/{id}/assign` | POST |
| Assign script | `/beta/deviceManagement/deviceShellScripts/{id}/assign` | POST |
| Assign catalog | `/beta/deviceManagement/configurationPolicies/{id}/assign` | POST |

## What Changes

### Agent (`main.swift`)
- **Remove**: `/prerequisites`, `/upload`, `/upload-file` endpoints
- **Remove**: All PowerShell module installs except `Microsoft.Graph.Authentication`
- **Remove**: All Graph operation logic (prereqs, file processing, template replacement)
- **Add**: `/token` endpoint that runs `(Get-MgContext).AccessToken` or equivalent
- **Simplify**: `/connect` to only do auth + return tenant info
- **Simplify**: State management (no more operation queues, file processing)

### PowerShell Module (`IntuneBaseBuild.psm1`)
- **Remove entirely** or reduce to a thin auth helper

### Frontend (`intune_base_build.html`)
- **Rewrite**: All 4 steps to use browser-side JS
- **Add**: Graph API client module (fetch wrapper with token)
- **Add**: pkg parser integration (pkgparser-REAL.js)
- **Add**: Encryption + upload integration (adapted from Intune JS)
- **Add**: Template replacement logic (`{tenant_id}`, `{org_name}`) in browser
- **Keep**: S3 file list loading, UI wizard structure, progress display

### Flask Backend (`main.py`)
- **Keep**: `/api/intune-file-list` proxy (still needed for CORS)
- **No other changes needed**

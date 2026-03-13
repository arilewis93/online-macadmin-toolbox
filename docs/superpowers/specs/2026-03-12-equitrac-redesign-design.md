# Equitrac Tool Redesign — Config-Driven 3+1 Section UX

## Problem

The current Equitrac tool has a 7-section wizard that doesn't mirror the real-world Equitrac setup flow. Several EQPrinterUtilityX Preferences settings are hardcoded in the postinstall script rather than configurable through the web tool. The printer section only supports DRE-type printers, not direct IP printers. The goal is to reorganize the UI into logical sections that match what an admin actually does when setting up Equitrac, and ensure the generated config profile contains all settings so the static postinstall script can read everything it needs.

## Approach

Horizontal stepper wizard (matching Intune Base Build UX pattern) with 6 steps: Enrollment, Preferences, Printers, Packages, Build, Deploy.

## Step 1: Enrollment

The "command line" setup — fields that come from or relate to the `NDI.SecurityConfig.sh enroll` command.

### Quick Import Card
- Paste field for the full enrollment command
- `parseCommand()` auto-populates all fields below on paste
- Same parsing logic as today

### Credentials Card
| Field | Type | Required | Config Key |
|---|---|---|---|
| Domain | text | yes | `SECURITY_DOMAIN` |
| Username | text | yes | `SECURITY_USERNAME` |
| Password | password | yes | `SECURITY_PASSWORD` |
| Security Node | text | yes | `SECURITY_NODE` |
| Datacenter Name | text | yes | `DATACENTER_NAME` |

### DRC Card
| Field | Type | Default | Config Key |
|---|---|---|---|
| Install DRC | toggle | off | `INSTALL_DRC` |

## Step 2: Preferences (EQPrinterUtilityX Settings)

Mirrors the EQPrinterUtilityX Preferences dialog, using styled toggles instead of native checkboxes.

### Features Card
Two-column grid of toggles:

| Field | Config Key | Default |
|---|---|---|
| Client Billing | `PREF_CLIENT_BILLING` | off |
| Release Key | `PREF_RELEASE_KEY` | off |
| Prompt for Login | `PREF_PROMPT_FOR_LOGIN` | off |
| Allow Rename Document | `PREF_ALLOW_RENAME_DOCUMENT` | off |
| Cost Preview | `PREF_COST_PREVIEW` | off |

### CAS Server Card
| Field | Type | Required | Config Key |
|---|---|---|---|
| CAS Server | text | yes | `CAS_SERVER` |

### DRC System Name Card
| Field | Type | Config Key | Notes |
|---|---|---|---|
| Mode | radio group (IP Address / Bonjour Name / DNS Hostname) | `DRC_SYS_NAME_MODE` (1/2/3) | |
| Skip Link Local Addresses | toggle | `SKIP_LINK_LOCAL_IP` | Visible when mode is IP Address or DNS Hostname. Default on. |
| Interface | dropdown (any, en0, en1, etc.) | `IP_ADDR_INTERFACE` | Visible when mode is IP Address or DNS Hostname. Default "any" (empty string). |
| Register with DNS Server | toggle | `REG_MACHINE_ID_DNS` | Always visible in this card. Default off. |

### Login Options Card
| Field | Type | Config Key | Default |
|---|---|---|---|
| Cache Login | toggle | `USE_CACHED_LOGIN` | off |
| Prompt for Password | toggle | `PROMPT_FOR_PASSWORD` | on |
| User ID Label | text | `USER_ID_LABEL` | empty |

### Ignore Command and Control Card
| Field | Type | Config Key | Default |
|---|---|---|---|
| Ignore Printer 'Command and Control' Print Jobs | toggle | `IGNORE_SUPPLIES_LEVEL_JOB` | off |

## Step 3: Printers

Supports two printer types: DRE (Equitrac follow-you) and IP (direct). Mixed types allowed in a single config.

### DRE Server Card
| Field | Type | Required | Config Key |
|---|---|---|---|
| DRE Server | text | yes (if any DRE printers) | `DRE_SERVER` |

### Printer List Card
- Shows added printers as rows: name, type badge (DRE / IP), edit/remove buttons
- Empty state: "No printers added."
- "Add Printer" button reveals a type selector sub-form

### New Printer (DRE) Sub-Form
| Field | Type | Notes |
|---|---|---|
| Printer Name | text | CUPS queue name |
| PPD | text | Default "Generic" |

URI built automatically: `eqtrans://DRE_SERVER/PRINTER_NAME`

### New IP Printer Sub-Form
| Field | Type | Notes |
|---|---|---|
| IP Address | text | |
| Name | text | CUPS queue name |
| Protocol | radio (Raw / LPR) | |
| Port | text | Visible when Raw. Default 9100. |
| Queue | text | Visible when LPR. |
| PPD | text | Default "Generic" |

URI built as `socket://IP:PORT` (Raw) or `lpd://IP/QUEUE` (LPR).

### Config Profile Structure for Printers

Each printer stored in the `PRINTERS` array with these keys:

| Key | Type | Present For |
|---|---|---|
| `type` | string (`dre` / `ip`) | all |
| `name` | string | all |
| `ppd` | string | all |
| `ip` | string | IP only |
| `protocol` | string (`raw` / `lpr`) | IP only |
| `port` | integer | IP + raw only |
| `queue` | string | IP + lpr only |

## Step 4: Packages

### Equitrac Installer Card
| Field | Type | Required | Config Key |
|---|---|---|---|
| Installer PKG filename | text | yes | `INSTALLER_PKG` |

### Print Drivers Card
- Dynamic list of driver PKG filenames (add/remove)
- Config key: `PRINT_DRIVERS` (array of strings)
- Empty state: "No drivers added."

## Step 5: Build

Generates the build script based on config. Displays script with syntax highlighting, copy and download buttons. Same logic as today.

## Step 6: Deploy

Displays:
1. Generated mobileconfig XML with copy/download
2. Link to download Equitrac.pkg from S3
3. Reference to the built payload package

## UX Pattern: Horizontal Stepper (Intune Base Build)

- Horizontal stepper bar at top: numbered dots with labels, connecting lines
- Three visual states: pending (gray), active (accent + glow), complete (green + checkmark)
- One section visible at a time
- Back/Next buttons; can click completed steps to revisit
- Status pill: NOT SAVED → UNSAVED → READY

## Postinstall Script Updates

The `scripts/equitrac_postinstall.sh` must be updated to:

1. **Read new config keys**: `SKIP_LINK_LOCAL_IP`, `IP_ADDR_INTERFACE`, `REG_MACHINE_ID_DNS`, `USE_CACHED_LOGIN`, `PROMPT_FOR_PASSWORD`, `USER_ID_LABEL`, `IGNORE_SUPPLIES_LEVEL_JOB`

2. **Write new values to EquitracOfficePrefs**: Map the new config keys to their EquitracOfficePrefs equivalents:
   - `SKIP_LINK_LOCAL_IP` → `SkipLinkLocalIPAddr`
   - `IP_ADDR_INTERFACE` → `IPAddrInterfaceName`
   - `REG_MACHINE_ID_DNS` → `RegMachineIDWithDNSSvr`
   - `USE_CACHED_LOGIN` → `UseCachedLogin`
   - `PROMPT_FOR_PASSWORD` → `PromptForPasssword` (note: triple-s is Equitrac's own typo)
   - `USER_ID_LABEL` → `UserIDLabelText`
   - `IGNORE_SUPPLIES_LEVEL_JOB` → `IgnoreSuppliesLevelJob`

3. **Handle mixed printer types in `create_printers()`**:
   - Read `type` key from each printer dict
   - DRE printers: `eqtrans://DRE_SERVER/NAME` (existing logic)
   - IP printers: build URI from `ip`, `protocol`, `port`/`queue`:
     - Raw: `socket://IP:PORT`
     - LPR: `lpd://IP/QUEUE`

## Files Changed

| File | Change |
|---|---|
| `app/templates/tools/equitrac.html` | Full rewrite — new 6-step horizontal stepper wizard, new fields, new printer sub-forms, updated `buildXML()` and `buildScriptContent()` |
| `scripts/equitrac_postinstall.sh` | Read new config keys, write to EquitracOfficePrefs dynamically, handle mixed printer types in `create_printers()` |

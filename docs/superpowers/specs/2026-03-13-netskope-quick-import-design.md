# Netskope Tool: Quick Import & .plist Fix

**Date:** 2026-03-13
**Scope:** Minimal additions to existing Netskope preinstall script generator

## Context

The Netskope tool (`app/templates/tools/netskope.html`) already supports 6 deployment modes (IdP, Email/AD, UPN, Per-User, Preference Email, CLI) with full script generation including fail-close, silent mode, auth/encryption tokens, and enforce enrollment.

Netskope's official Intune deployment docs use a `set -- 0 0 0 ...` command format to configure positional parameters. Admins often have this line from existing deployments or documentation and want to use it as a starting point.

Additionally, the Preference Email and UPN (plist source) modes have a gotcha: the user enters a preference domain identifier (e.g., `com.company.netskope`) but the generated file-existence check in the script requires the `.plist` extension.

## Changes

### 1. Quick Import Card

A new card inserted at the top of the tool (before the Mode Selection card), following the Equitrac quick-import pattern.

**UI:**
- Single-line input field with placeholder: `set -- 0 0 0 idp eu.goskope.com abcde 0 ...`
- Import button adjacent to the input
- Enter key triggers import
- Error span for parse failures (hidden by default)
- Success flash on the Import button ("Imported") matching Equitrac's pattern

**Parser logic:**

Tokenize the pasted string by whitespace. Strip `set`, `--`, and the first three `0` placeholders to produce a zero-indexed array `args[]` where `args[0]` corresponds to Netskope's "Parameter 4."

**IDP detection** — `args[0]` is `idp` (case-insensitive):
- Set mode dropdown to `idp`
- `args[1]` → `idpDomain` field
- `args[2]` → `idpTenant` field
- `args[3]` → `idpRequestEmail` toggle (value `1` = checked, `0` = unchecked)
- Scan remaining tokens for `peruserconfig` keyword → if found, check `idpPerUser` toggle. Note: the `set --` format does not include host/token values for per-user config, so `idpHost` and `idpToken` will remain empty — the user must fill them manually. The import populates what it can and the download button stays disabled until all required fields are filled (existing validation handles this).
- Scan remaining tokens for `enrollauthtoken=<value>` → if found, check `optAuthToken` toggle and populate `optAuthTokenVal`
- Scan remaining tokens for `enrollencryptiontoken=<value>` → if found, check `optEncToken` toggle and populate `optEncTokenVal`

**addon- URL detection** — `args[0]` starts with `addon-`:

Multiple modes (Preference Email, UPN, Per-User) share the `addon-` prefix. The parser scans all tokens for distinguishing keywords to select the correct mode:

- If `preference_email` keyword found → **Preference Email** mode:
  - Set mode dropdown to `prefemail`
  - `args[0]` → `prefemailTenantUrl` field
  - `args[1]` → `prefemailOrgKey` field
  - `args[2]` → `prefemailPrefFile` field (normalize: append `.plist` if not already present)
  - Scan for `enrollauthtoken=<value>` → if found, check `optAuthToken` toggle and populate `optAuthTokenVal`
  - Scan for `enrollencryptiontoken=<value>` → if found, check `optEncToken` toggle and populate `optEncTokenVal`

- If no distinguishing keyword found → **default to Preference Email** mode with the same field mapping above (this is the most common `addon-` format in Netskope's Intune docs). UPN and Per-User modes are not represented in Netskope's standard `set --` format and are out of scope for quick import — users select those modes manually.

**Unrecognized format** — `args[0]` is neither `idp` nor starts with `addon-`. Show error span: "Unrecognized format. Paste a `set -- 0 0 0 ...` command from Netskope's Intune deployment docs."

**Toggle manipulation:** When programmatically checking toggles during import, set both the checkbox `.checked = true` AND add the `enabled` class to the parent `.toggle-row` label, since the existing `nsToggle()` function manages both but is not called during import. This ensures visual state matches functional state.

**Field clearing:** The parser does not clear fields from other modes before populating. This matches Equitrac's behavior. Since `nsModeChanged()` hides irrelevant cards, stale values in hidden fields have no user impact, and existing validation only checks visible/active fields.

After populating fields:
- Switch mode dropdown value
- Call `nsModeChanged()` to show/hide the correct cards
- Call `nsUpdate()` to re-validate and enable/disable the download button
- Flash success on the Import button

### 2. `.plist` Normalization in Script Generation

In the JavaScript builder functions, normalize the preference file name before writing it into the generated bash script. If the user's input doesn't end with `.plist`, append it.

**Affected functions:**
- `buildPrefemailScript()` — the `prefFile` variable (line ~560)
- `buildUpnScript()` — the `prefFile` variable when `upnSource === 'pref'` (line ~513)

**Implementation:** A shared helper inside the IIFE:
```javascript
function normalizePlist(name) {
  if (!name) return name;
  return name.replace(/\.plist$/i, '') + '.plist';
}
```

This strips any existing `.plist` suffix first (case-insensitive) then re-adds it, avoiding double-extension edge cases like `foo.plist.plist`.

**Call order:** `esc(normalizePlist(val(...)))` — normalize the raw value first, then escape for bash. This is the semantically correct order since `esc()` could theoretically alter the suffix.

The user's input field value is left unchanged — normalization only applies at script generation time.

## Files Modified

- `app/templates/tools/netskope.html` — Quick Import card HTML + parser function + `.plist` normalization helper + updated builder functions

## Files NOT Modified

- `app/views/main.py` — tool already registered in `TOOL_NAMES`
- `app/templates/dashboard.html` — card already exists
- No new files created

## Out of Scope

- No changes to existing deployment modes or script generation logic (beyond the `.plist` fix)
- No changes to validation, UI layout, or mode switching behavior
- No addition of new deployment modes

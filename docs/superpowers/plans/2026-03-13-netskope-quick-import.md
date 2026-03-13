# Netskope Quick Import & .plist Fix Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Quick Import card to the Netskope tool that parses `set -- 0 0 0 ...` commands into form fields, and fix `.plist` extension handling in generated scripts.

**Architecture:** All changes are in one file (`app/templates/tools/netskope.html`). A new HTML card is inserted before the existing Mode Selection card. A `parseCommand()` function and `normalizePlist()` helper are added inside the existing IIFE. Two existing builder functions are updated to use `normalizePlist()`.

**Tech Stack:** HTML, vanilla JavaScript (using `var` per project convention), bash script generation

**Spec:** `docs/superpowers/specs/2026-03-13-netskope-quick-import-design.md`

**No tests:** This project has no test suites (per CLAUDE.md).

---

## Chunk 1: All Changes

### File Map

- **Modify:** `app/templates/tools/netskope.html`
  - Insert Quick Import card HTML (after line 24, before the Mode Selection card at line 26)
  - Add `normalizePlist()` helper inside the IIFE (after `esc()` helper, ~line 302)
  - Add `parseCommand()` function inside the IIFE (before `window.nsToggle`, ~line 319)
  - Add `setToggleOn()` helper for programmatic toggle checking
  - Update `buildUpnScript()` at line 513: use `normalizePlist()`
  - Update `buildPrefemailScript()` at line 560: use `normalizePlist()`

---

### Task 1: Add Quick Import card HTML

**Files:**
- Modify: `app/templates/tools/netskope.html:24-26`

- [ ] **Step 1: Insert Quick Import card after the section-header closing div (line 24), before the Mode Selection comment (line 26)**

```html
      <!-- Quick Import -->
      <div class="card">
        <div class="card-title">Quick Import</div>
        <div class="field-grid single">
          <div class="field">
            <label>PASTE SET COMMAND</label>
            <div style="display:flex;gap:0.5rem">
              <input type="text" id="cmdPaste" placeholder="set -- 0 0 0 idp eu.goskope.com abcde 0 ..." style="flex:1"
                     onkeydown="if(event.key==='Enter'){parseCommand();event.preventDefault()}">
              <button class="btn btn-primary" id="importBtn" onclick="parseCommand()" style="white-space:nowrap">Import</button>
            </div>
            <span class="field-error" id="err-cmdPaste">Unrecognized format. Paste a <code>set -- 0 0 0 ...</code> command from Netskope's Intune deployment docs.</span>
          </div>
        </div>
      </div>

```

- [ ] **Step 2: Verify the page loads correctly**

Run: Open `http://localhost:5001/netskope` in browser. Confirm the Quick Import card appears above the Deployment Mode card. The Import button should be visible. Typing in the field and pressing Enter should do nothing yet (function not defined — that's expected at this step).

- [ ] **Step 3: Commit**

```bash
git add app/templates/tools/netskope.html
git commit -m "feat(netskope): add Quick Import card HTML"
```

---

### Task 2: Add `normalizePlist()` helper

**Files:**
- Modify: `app/templates/tools/netskope.html:~302` (inside the IIFE, after the `esc()` function)

- [ ] **Step 1: Add `normalizePlist()` after the `esc()` function (line 302)**

Insert after the closing `}` of the `esc()` function:

```javascript
  /** Ensure plist filename ends with .plist extension. */
  function normalizePlist(name) {
    if (!name) return name;
    return name.replace(/\.plist$/i, '') + '.plist';
  }
```

- [ ] **Step 2: Commit**

```bash
git add app/templates/tools/netskope.html
git commit -m "feat(netskope): add normalizePlist helper"
```

---

### Task 3: Add `setToggleOn()` helper and `parseCommand()` function

**Files:**
- Modify: `app/templates/tools/netskope.html` (inside the IIFE, before `window.nsToggle`)

- [ ] **Step 1: Add `setToggleOn()` helper before `window.nsToggle` (~line 319)**

This helper programmatically checks a toggle and applies the CSS class, matching what `nsToggle()` does visually:

```javascript
  /** Programmatically check a toggle and apply visual state. */
  function setToggleOn(id) {
    var cb = document.getElementById(id);
    if (!cb || cb.checked) return;
    cb.checked = true;
    var row = cb.closest('.toggle-row');
    if (row) row.classList.add('enabled');
  }
```

- [ ] **Step 2: Add `parseCommand()` function after `setToggleOn()`**

```javascript
  /** Parse a Netskope set -- command and populate form fields. */
  window.parseCommand = function() {
    var raw = document.getElementById('cmdPaste').value.trim();
    var errEl = document.getElementById('err-cmdPaste');
    errEl.classList.remove('visible');

    if (!raw) return;

    // Tokenize and strip "set", "--", and exactly three leading 0s
    var tokens = raw.split(/\s+/);
    var startIdx = 0;
    if (tokens[0] === 'set') startIdx++;
    if (tokens[startIdx] === '--') startIdx++;
    // Skip exactly 3 leading 0s (Netskope's fixed positional params 1-3)
    for (var z = 0; z < 3 && startIdx < tokens.length && tokens[startIdx] === '0'; z++) startIdx++;

    var args = tokens.slice(startIdx);
    if (args.length < 2) {
      errEl.classList.add('visible');
      return;
    }

    var mode = null;

    // Scan all args for token= style values and keywords
    var enrollAuth = '';
    var enrollEnc = '';
    var hasPerUserConfig = false;
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      if (a.toLowerCase().indexOf('enrollauthtoken=') === 0) {
        enrollAuth = a.substring('enrollauthtoken='.length);
      } else if (a.toLowerCase().indexOf('enrollencryptiontoken=') === 0) {
        enrollEnc = a.substring('enrollencryptiontoken='.length);
      } else if (a.toLowerCase() === 'peruserconfig') {
        hasPerUserConfig = true;
      }
    }

    // Detect mode from args[0]
    if (args[0].toLowerCase() === 'idp') {
      mode = 'idp';
      document.getElementById('nsMode').value = 'idp';

      if (args[1]) document.getElementById('idpDomain').value = args[1];
      if (args[2]) document.getElementById('idpTenant').value = args[2];

      // args[3] is email request: 1 = checked, 0 = unchecked
      if (args[3] === '1') {
        setToggleOn('idpRequestEmail');
      }

      if (hasPerUserConfig) {
        setToggleOn('idpPerUser');
      }

    } else if (args[0].toLowerCase().indexOf('addon-') === 0) {
      mode = 'prefemail';
      document.getElementById('nsMode').value = 'prefemail';

      document.getElementById('prefemailTenantUrl').value = args[0];
      if (args[1]) document.getElementById('prefemailOrgKey').value = args[1];
      if (args[2]) {
        // Normalize .plist on the pref file name
        var pf = args[2];
        if (!/\.plist$/i.test(pf)) pf += '.plist';
        document.getElementById('prefemailPrefFile').value = pf;
      }

    } else {
      errEl.classList.add('visible');
      return;
    }

    // Apply enrollment tokens
    if (enrollAuth) {
      setToggleOn('optAuthToken');
      document.getElementById('optAuthTokenVal').value = enrollAuth;
    }
    if (enrollEnc) {
      setToggleOn('optEncToken');
      document.getElementById('optEncTokenVal').value = enrollEnc;
    }

    // Switch UI and validate
    nsModeChanged();

    // Flash success on import button
    var btn = document.getElementById('importBtn');
    var orig = btn.textContent;
    btn.textContent = 'Imported';
    btn.style.color = 'var(--green)';
    setTimeout(function() { btn.textContent = orig; btn.style.color = ''; }, 2000);
  };
```

- [ ] **Step 3: Verify Quick Import works end-to-end**

Open `http://localhost:5001/netskope` and test with these inputs:

1. IDP single-user: `set -- 0 0 0 idp eu.goskope.com abcde 0 enrollencryptiontoken=abc123`
   - Expected: Mode switches to IdP, domain=eu.goskope.com, tenant=abcde, request email unchecked, encryption token checked with value abc123

2. IDP multi-user: `set -- 0 0 0 idp eu.goskope.com abcde 1 peruserconfig enrollencryptiontoken=abc123`
   - Expected: Mode switches to IdP, request email checked, per-user config checked, host/token fields visible but empty, download button disabled

3. Preference email: `set -- 0 0 0 addon-abcde.eu.goskope.com xxxx PreferenceProfileName.plist preference_email enrollauthtoken=zzz enrollencryptiontoken=yyy`
   - Expected: Mode switches to Preference Email, all fields populated, both tokens checked

4. Preference email without .plist: `set -- 0 0 0 addon-abcde.eu.goskope.com xxxx com.company.netskope preference_email`
   - Expected: pref file field shows `com.company.netskope.plist`

5. Invalid: `set -- 0 0 0 something`
   - Expected: Error message shown

- [ ] **Step 4: Commit**

```bash
git add app/templates/tools/netskope.html
git commit -m "feat(netskope): add Quick Import parser for set -- commands"
```

---

### Task 4: Fix `.plist` normalization in script builders

**Files:**
- Modify: `app/templates/tools/netskope.html:513,560`

- [ ] **Step 1: Update `buildUpnScript()` at line 513**

Change:
```javascript
      var prefFile = esc(val('upnPrefFile'));
```
To:
```javascript
      var prefFile = esc(normalizePlist(val('upnPrefFile')));
```

- [ ] **Step 2: Update `buildPrefemailScript()` at line 560**

Change:
```javascript
    var prefFile = esc(val('prefemailPrefFile'));
```
To:
```javascript
    var prefFile = esc(normalizePlist(val('prefemailPrefFile')));
```

- [ ] **Step 3: Verify .plist normalization works**

Open `http://localhost:5001/netskope`, select Preference Email mode:
1. Enter `com.company.netskope` (no .plist) in pref file field, fill other required fields, download script
   - Expected: Script contains `com.company.netskope.plist` in the file path
2. Enter `com.company.netskope.plist` (with .plist), download script
   - Expected: Script contains `com.company.netskope.plist` (not doubled)

Repeat for UPN mode with plist source.

- [ ] **Step 4: Commit**

```bash
git add app/templates/tools/netskope.html
git commit -m "fix(netskope): normalize .plist extension in generated scripts"
```

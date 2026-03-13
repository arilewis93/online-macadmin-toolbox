# Equitrac Tool Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Equitrac Config Profile Generator from a 7-section sidebar wizard into a 6-step horizontal stepper wizard (matching Intune Base Build UX), add new configurable EQPrinterUtilityX Preferences fields, support mixed DRE/IP printer types, and update the postinstall script to read all new config keys.

**Architecture:** Single-file HTML template rewrite (`equitrac.html`) replacing the sidebar nav with a horizontal stepper. Config profile (mobileconfig plist) gains new keys. Postinstall script (`equitrac_postinstall.sh`) updated to read new keys and handle both printer URI formats.

**Tech Stack:** HTML/CSS/JS (inline in Jinja2 template), Bash (postinstall script). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-03-12-equitrac-redesign-design.md`

**No tests** — this project has no test suites (per CLAUDE.md).

**Conventions:**
- Use `var` (not `let`/`const`) throughout all JS — per CLAUDE.md browser compatibility requirement. The existing file uses `const`/`let` in places; convert all to `var` during the rewrite.
- Pre-checked toggle elements must have `class="toggle-row enabled"` in the HTML so visual state matches on page load.
- Reference functions/patterns (not line numbers) when modifying code, since line numbers shift during rewrites.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `app/templates/tools/equitrac.html` | Rewrite | 6-step horizontal stepper wizard, all fields, `buildXML()`, `buildScriptContent()`, validation, navigation |
| `scripts/equitrac_postinstall.sh` | Modify | Read new config keys, write to EquitracOfficePrefs from config, handle mixed printer types |

---

## Chunk 1: HTML Template — Stepper Shell & Step 1 (Enrollment)

### Task 1: Replace sidebar nav with horizontal stepper and set up navigation

**Files:**
- Modify: `app/templates/tools/equitrac.html`

Replace the entire `<nav>` sidebar, progress bar, and navigation JS with the horizontal stepper pattern from `intune_base_build.html`.

- [ ] **Step 1: Read reference files**

Read `app/templates/tools/intune_base_build.html` lines 18-81 for stepper CSS, and the stepper HTML (search for `intune-stepper` class). Also read `app/static/css/tools.css` for existing styles that must be preserved.

- [ ] **Step 2: Replace the progress bar and sidebar nav HTML**

In `equitrac.html`, replace:
- The `<div class="progress-bar">` block (line 18-20)
- The `<nav id="sideNav">` block (lines 24-49)
- The `<div class="shell">` wrapper

With a horizontal stepper bar inside `{% block extra_styles %}` for CSS and new HTML. The stepper has 6 items: Enrollment, Preferences, Printers, Packages, Build, Deploy.

Stepper HTML structure (place before `<main>` inside `{% block content %}`):
```html
<div class="eq-stepper">
  <!-- item 1 -->
  <div class="eq-stepper-item clickable" data-step="0" onclick="stepClick(0)">
    <div class="eq-step-dot active" id="dot-0">1</div>
    <span class="eq-step-label active" id="label-0">Enrollment</span>
  </div>
  <div class="eq-step-line" id="line-0"></div>
  <!-- items 2-6 follow same pattern with ids dot-1..5, label-1..5, line-1..4 -->
</div>
```

Use `eq-` prefix (not `intune-`) to avoid CSS collisions. Copy the stepper CSS from intune_base_build.html, renaming classes from `intune-` to `eq-`.

- [ ] **Step 3: Rewrite the navigation JS**

Replace the existing `SECTIONS`, `navLink()`, and `navigate()` functions with stepper-aware navigation:

```javascript
var STEPS = ['s-enrollment','s-preferences','s-printers','s-packages','s-build','s-deploy'];
var currentStep = 0;
var maxStep = 0; // furthest step reached

function goToStep(idx) {
  if (idx < 0 || idx >= STEPS.length) return;
  // Hide all sections
  STEPS.forEach(function(id) {
    document.getElementById(id).classList.remove('active');
  });
  // Show target
  document.getElementById(STEPS[idx]).classList.add('active');
  currentStep = idx;
  if (idx > maxStep) maxStep = idx;
  updateStepper();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function updateStepper() {
  for (var i = 0; i < STEPS.length; i++) {
    var dot = document.getElementById('dot-' + i);
    var label = document.getElementById('label-' + i);
    dot.className = 'eq-step-dot';
    label.className = 'eq-step-label';
    if (i < currentStep) {
      dot.className = 'eq-step-dot complete';
      dot.innerHTML = '&#10003;';
      label.className = 'eq-step-label complete';
    } else if (i === currentStep) {
      dot.className = 'eq-step-dot active';
      dot.textContent = String(i + 1);
      label.className = 'eq-step-label active';
    } else {
      dot.textContent = String(i + 1);
    }
    if (i < STEPS.length - 1) {
      var line = document.getElementById('line-' + i);
      line.className = i < currentStep ? 'eq-step-line complete' : 'eq-step-line';
    }
  }
  // Update clickable state
  document.querySelectorAll('.eq-stepper-item').forEach(function(item, i) {
    item.classList.toggle('clickable', i <= maxStep);
  });
}

function stepClick(idx) {
  if (idx <= maxStep) goToStep(idx);
}

function nextStep() {
  if (validateCurrentStep()) goToStep(currentStep + 1);
}

function prevStep() {
  goToStep(currentStep - 1);
}
```

- [ ] **Step 4: Update all section IDs**

Rename section IDs in the HTML:
- `s-security` → `s-enrollment`
- `s-servers` → remove (content redistributed)
- `s-printers` → `s-printers` (keep)
- `s-drivers` → `s-packages`
- `s-features` → remove (content moves to `s-preferences`)
- `s-build` → `s-build` (keep)
- `s-generate` → `s-deploy`

Add new section: `s-preferences`

- [ ] **Step 5: Verify the stepper renders and navigates**

Run `python run.py` and open http://localhost:5001/equitrac. Verify:
- Horizontal stepper bar renders with 6 numbered dots
- Clicking dots navigates between sections
- Back/Next buttons work
- Active dot has accent glow, completed dots show green checkmark

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "refactor: replace Equitrac sidebar with horizontal stepper wizard"
```

---

### Task 2: Build Step 1 — Enrollment section

**Files:**
- Modify: `app/templates/tools/equitrac.html`

Restructure the Enrollment section with Quick Import, Credentials, and DRC toggle cards.

- [ ] **Step 1: Rewrite the s-enrollment section HTML**

The section should contain:

**Section header:**
```html
<div class="section active" id="s-enrollment">
  <div class="section-header">
    <div class="section-tag">01 / Enrollment</div>
    <div class="section-title">Security Enrollment</div>
    <div class="section-desc">Credentials from the NDI.SecurityConfig.sh enrollment command.</div>
  </div>
```

**Quick Import card** — keep existing structure and `parseCommand()` logic from the current `s-security` section (lines 61-73). No changes needed to the card itself.

**Credentials card** — keep existing Domain, Username, Password fields (lines 76-94) and Node & Datacenter card (lines 96-110). Merge into a single "Credentials" card with a 3-column grid for domain/username/password and a 2-column grid for node/datacenter.

**DRC card** — new card with a single toggle (replacing the old `<select>`):
```html
<div class="card">
  <div class="card-title">Document Routing Client</div>
  <div class="toggle-group">
    <label class="toggle-row" id="tr-installDrc" onclick="toggleDrc()">
      <input type="checkbox" id="installDrc">
      <div class="toggle-info">
        <div class="toggle-label">Install DRC</div>
        <div class="toggle-desc">Install the Document Routing Client alongside the Print Client</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
  </div>
</div>
```

**Section footer** with Back (disabled on step 1) and Next:
```html
<div class="section-footer">
  <span></span>
  <button class="btn btn-primary" onclick="nextStep()">Next &rarr;</button>
</div>
```

- [ ] **Step 2: Update parseCommand() for the new DRC toggle**

The current `parseCommand()` sets `installDrc` as a `<select>` value. Update it to check/uncheck the checkbox:

Change line 974 from:
```javascript
document.getElementById('installDrc').value = hasDrc ? 'true' : 'false';
```
To:
```javascript
var drcCb = document.getElementById('installDrc');
drcCb.checked = hasDrc;
document.getElementById('tr-installDrc').classList.toggle('enabled', hasDrc);
```

- [ ] **Step 3: Add toggleDrc() function**

```javascript
function toggleDrc() {
  var cb = document.getElementById('installDrc');
  cb.checked = !cb.checked;
  document.getElementById('tr-installDrc').classList.toggle('enabled', cb.checked);
  // Show/hide DRC System Name card in Preferences
  updateDrcVisibility();
  markDirty();
}

function updateDrcVisibility() {
  var show = document.getElementById('installDrc').checked;
  var card = document.getElementById('drcSystemNameCard');
  if (card) card.style.display = show ? '' : 'none';
}
```

- [ ] **Step 4: Add per-step validation**

```javascript
function validateCurrentStep() {
  if (currentStep === 0) {
    return validateFields(['secDomain','secUsername','secPassword','secNode','datacenterName']);
  }
  if (currentStep === 1) {
    return validateFields(['casServer']);
  }
  if (currentStep === 2) {
    return validatePrinterStep();
  }
  if (currentStep === 3) {
    return validateFields(['installerPkgName']);
  }
  return true;
}

function validateFields(ids) {
  var ok = true;
  ids.forEach(function(id) {
    var el = document.getElementById(id);
    var errEl = document.getElementById('err-' + id);
    if (!el.value.trim()) {
      el.classList.add('invalid');
      if (errEl) errEl.classList.add('visible');
      ok = false;
    } else {
      el.classList.remove('invalid');
      if (errEl) errEl.classList.remove('visible');
    }
  });
  return ok;
}

function validatePrinterStep() {
  // DRE Server required only if any DRE printers exist
  var hasDre = printers.some(function(p) { return p.type === 'dre'; });
  if (hasDre) {
    return validateFields(['dreServer']);
  }
  return true;
}
```

- [ ] **Step 5: Verify Step 1**

Run `python run.py`, open http://localhost:5001/equitrac. Verify:
- Quick Import populates all fields including DRC toggle
- All 5 credential fields render with validation
- DRC toggle works
- Next button validates before advancing

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "feat: build Equitrac Step 1 (Enrollment) with Quick Import and DRC toggle"
```

---

## Chunk 2: Steps 2-3 (Preferences & Printers)

### Task 3: Build Step 2 — Preferences section

**Files:**
- Modify: `app/templates/tools/equitrac.html`

- [ ] **Step 1: Create the s-preferences section HTML**

Insert after `s-enrollment`, before `s-printers`. Contains 6 cards:

**Features card** — two-column grid of the 5 existing feature toggles (move from old `s-features`). Keep the same toggle-row structure and IDs (`clientBilling`, `promptForLogin`, `costPreview`, `allowRenameDocument`, `releaseKey`). Wrap in a 2-column CSS grid:

```html
<div class="card">
  <div class="card-title">Features</div>
  <div class="toggle-grid">
    <!-- Column 1 -->
    <label class="toggle-row" id="tr-clientBilling" onclick="toggleFeature('clientBilling')">
      <input type="checkbox" id="clientBilling">
      <div class="toggle-info">
        <div class="toggle-label">Client Billing</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
    <label class="toggle-row" id="tr-promptForLogin" onclick="toggleFeature('promptForLogin')">
      <input type="checkbox" id="promptForLogin">
      <div class="toggle-info">
        <div class="toggle-label">Prompt for Login</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
    <label class="toggle-row" id="tr-costPreview" onclick="toggleFeature('costPreview')">
      <input type="checkbox" id="costPreview">
      <div class="toggle-info">
        <div class="toggle-label">Cost Preview</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
    <!-- Column 2 -->
    <label class="toggle-row" id="tr-releaseKey" onclick="toggleFeature('releaseKey')">
      <input type="checkbox" id="releaseKey">
      <div class="toggle-info">
        <div class="toggle-label">Release Key</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
    <label class="toggle-row" id="tr-allowRenameDocument" onclick="toggleFeature('allowRenameDocument')">
      <input type="checkbox" id="allowRenameDocument">
      <div class="toggle-info">
        <div class="toggle-label">Allow Rename Document</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
  </div>
</div>
```

Add CSS for `.toggle-grid`:
```css
.toggle-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0;
}
```

**CAS Server card:**
```html
<div class="card">
  <div class="card-title">CAS Server</div>
  <div class="field-grid single">
    <div class="field">
      <label>CAS SERVER <span class="required">*</span> <span class="hint">IP or hostname</span></label>
      <input type="text" id="casServer" placeholder="192.168.1.100" oninput="markDirty()">
      <span class="field-error" id="err-casServer">Required</span>
    </div>
  </div>
</div>
```

**DRC System Name card** (conditionally shown based on Install DRC toggle):
```html
<div class="card" id="drcSystemNameCard" style="display:none">
  <div class="card-title">DRC System Name</div>
  <div class="card-desc">How the DRC identifies this Mac to the server. Must be stable, resolvable on Windows, and unique.</div>
  <div class="field-grid single">
    <div class="field">
      <label>MODE</label>
      <div class="radio-group" id="drcModeGroup">
        <label class="radio-option"><input type="radio" name="drcMode" value="1" checked onchange="updateDrcMode();markDirty()"> IP Address</label>
        <label class="radio-option"><input type="radio" name="drcMode" value="2" onchange="updateDrcMode();markDirty()"> Bonjour Name</label>
        <label class="radio-option"><input type="radio" name="drcMode" value="3" onchange="updateDrcMode();markDirty()"> DNS Hostname</label>
      </div>
    </div>
  </div>
  <div id="drcIpOptions">
    <div class="field-grid">
      <div class="field">
        <label class="toggle-row compact enabled" id="tr-skipLinkLocal" onclick="togglePref('skipLinkLocal')">
          <input type="checkbox" id="skipLinkLocal" checked>
          <div class="toggle-info"><div class="toggle-label">Skip Link Local Addresses</div></div>
          <div class="toggle-switch"></div>
        </label>
      </div>
      <div class="field">
        <label>INTERFACE</label>
        <select id="ipAddrInterface" onchange="markDirty()">
          <option value="">any</option>
          <option value="en0">en0</option>
          <option value="en1">en1</option>
          <option value="en2">en2</option>
          <option value="en3">en3</option>
          <option value="en4">en4</option>
          <option value="en5">en5</option>
        </select>
      </div>
    </div>
  </div>
  <div class="toggle-group" style="margin-top:0.5rem">
    <label class="toggle-row" id="tr-regDns" onclick="togglePref('regDns')">
      <input type="checkbox" id="regDns">
      <div class="toggle-info"><div class="toggle-label">Register with DNS Server</div></div>
      <div class="toggle-switch"></div>
    </label>
  </div>
</div>
```

**Login Options card:**
```html
<div class="card">
  <div class="card-title">Login Options</div>
  <div class="field-grid">
    <label class="toggle-row" id="tr-cacheLogin" onclick="togglePref('cacheLogin')">
      <input type="checkbox" id="cacheLogin">
      <div class="toggle-info"><div class="toggle-label">Cache Login</div></div>
      <div class="toggle-switch"></div>
    </label>
    <label class="toggle-row enabled" id="tr-promptPassword" onclick="togglePref('promptPassword')">
      <input type="checkbox" id="promptPassword" checked>
      <div class="toggle-info"><div class="toggle-label">Prompt for Password</div></div>
      <div class="toggle-switch"></div>
    </label>
  </div>
  <div class="field-grid single" style="margin-top:0.5rem">
    <div class="field">
      <label>USER ID LABEL</label>
      <input type="text" id="userIdLabel" placeholder="" oninput="markDirty()">
    </div>
  </div>
</div>
```

**Ignore C&C card:**
```html
<div class="card">
  <div class="toggle-group">
    <label class="toggle-row" id="tr-ignoreCC" onclick="togglePref('ignoreCC')">
      <input type="checkbox" id="ignoreCC">
      <div class="toggle-info">
        <div class="toggle-label">Ignore Printer 'Command and Control' Print Jobs</div>
      </div>
      <div class="toggle-switch"></div>
    </label>
  </div>
</div>
```

**Section footer:**
```html
<div class="section-footer">
  <button class="btn btn-ghost" onclick="prevStep()">&larr; Back</button>
  <button class="btn btn-primary" onclick="nextStep()">Next &rarr;</button>
</div>
```

- [ ] **Step 2: Add the new JS functions for Preferences**

```javascript
function togglePref(id) {
  var cb = document.getElementById(id);
  cb.checked = !cb.checked;
  var row = document.getElementById('tr-' + id);
  if (row) row.classList.toggle('enabled', cb.checked);
  markDirty();
}

function updateDrcMode() {
  var mode = document.querySelector('input[name="drcMode"]:checked').value;
  var ipOpts = document.getElementById('drcIpOptions');
  // Show IP options for IP Address (1) and DNS Hostname (3), hide for Bonjour (2)
  ipOpts.style.display = (mode === '2') ? 'none' : '';
}
```

- [ ] **Step 3: Call updateDrcVisibility() on page load**

At the bottom of the script, after `renderPrinters()` and `renderDrivers()`, add:
```javascript
updateDrcVisibility();
updateDrcMode();
```

- [ ] **Step 4: Verify Step 2**

Run the dev server. Navigate to Step 2 (Preferences). Verify:
- Features show in 2-column grid with toggles
- CAS Server field renders with validation
- DRC System Name card hidden by default, shows when DRC is enabled in Step 1
- Bonjour mode hides IP options, IP/DNS modes show them
- Login Options toggles and User ID Label field work
- Ignore C&C toggle works

- [ ] **Step 5: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "feat: build Equitrac Step 2 (Preferences) with new configurable settings"
```

---

### Task 4: Build Step 3 — Printers section with DRE and IP support

**Files:**
- Modify: `app/templates/tools/equitrac.html`

- [ ] **Step 1: Update the printers state model**

Replace the existing `printers` array with a model that supports both types:

```javascript
var printers = [];
// Each printer: { type: 'dre'|'ip', name: '', ppd: 'generic', ip: '', protocol: 'raw', port: '9100', queue: '' }
```

- [ ] **Step 2: Rewrite the s-printers section HTML**

```html
<div class="section" id="s-printers">
  <div class="section-header">
    <div class="section-tag">03 / Printers</div>
    <div class="section-title">Printers</div>
    <div class="section-desc">Add Equitrac DRE printers or direct IP printers. Both types can coexist.</div>
  </div>

  <div class="card">
    <div class="card-title">DRE Server</div>
    <div class="field-grid single">
      <div class="field">
        <label>DRE SERVER <span class="hint">FQDN or IP — required if adding DRE printers</span></label>
        <input type="text" id="dreServer" placeholder="equitrac-server.yourdomain.com" oninput="markDirty()">
        <span class="field-error" id="err-dreServer">Required when DRE printers are defined</span>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-title">Printers</div>
    <div class="printer-list" id="printerList">
      <div class="empty-state" id="printerEmpty">No printers added.</div>
    </div>
    <div class="printer-add-buttons">
      <button class="btn-add" onclick="addPrinter('dre')">&#xFF0B; New Printer (DRE)</button>
      <button class="btn-add" onclick="addPrinter('ip')">&#xFF0B; New IP Printer</button>
    </div>
  </div>

  <div class="section-footer">
    <button class="btn btn-ghost" onclick="prevStep()">&larr; Back</button>
    <button class="btn btn-primary" onclick="nextStep()">Next &rarr;</button>
  </div>
</div>
```

- [ ] **Step 3: Rewrite printer JS — addPrinter, renderPrinters, removePrinter**

```javascript
function addPrinter(type) {
  if (type === 'dre') {
    printers.push({ type: 'dre', name: '', ppd: 'generic' });
  } else {
    printers.push({ type: 'ip', name: '', ppd: 'generic', ip: '', protocol: 'raw', port: '9100', queue: '' });
  }
  renderPrinters();
  markDirty();
  // Focus the first input of the new printer
  var items = document.querySelectorAll('.printer-item');
  var last = items[items.length - 1];
  if (last) last.querySelector('input').focus();
}

function removePrinter(i) {
  printers.splice(i, 1);
  renderPrinters();
  markDirty();
}

function updatePrinter(i, key, value) {
  printers[i][key] = value;
  if (key === 'protocol') renderPrinters(); // re-render to show/hide port vs queue
  markDirty();
}

function renderPrinters() {
  var list = document.getElementById('printerList');
  var empty = document.getElementById('printerEmpty');

  // Clear all printer items but keep the empty state element
  var items = list.querySelectorAll('.printer-item');
  items.forEach(function(el) { el.remove(); });

  if (printers.length === 0) {
    empty.style.display = '';
    return;
  }
  empty.style.display = 'none';

  printers.forEach(function(p, i) {
    var row = document.createElement('div');
    row.className = 'printer-item';

    var badge = p.type === 'dre'
      ? '<span class="printer-badge dre">DRE</span>'
      : '<span class="printer-badge ip">IP</span>';

    var fields = '';
    if (p.type === 'dre') {
      fields = ''
        + '<input type="text" value="' + esc(p.name) + '" placeholder="Queue name (e.g. HP-Colour-Mac)" oninput="updatePrinter(' + i + ',\'name\',this.value)">'
        + '<input type="text" value="' + esc(p.ppd) + '" placeholder="generic or /path/to/file.ppd" oninput="updatePrinter(' + i + ',\'ppd\',this.value)">';
    } else {
      var portField = p.protocol === 'raw'
        ? '<input type="text" value="' + esc(p.port) + '" placeholder="9100" oninput="updatePrinter(' + i + ',\'port\',this.value)" style="width:80px">'
        : '<input type="text" value="' + esc(p.queue) + '" placeholder="Queue name" oninput="updatePrinter(' + i + ',\'queue\',this.value)">';

      fields = ''
        + '<input type="text" value="' + esc(p.ip) + '" placeholder="IP Address" oninput="updatePrinter(' + i + ',\'ip\',this.value)">'
        + '<input type="text" value="' + esc(p.name) + '" placeholder="Printer name" oninput="updatePrinter(' + i + ',\'name\',this.value)">'
        + '<select onchange="updatePrinter(' + i + ',\'protocol\',this.value)">'
        + '  <option value="raw"' + (p.protocol === 'raw' ? ' selected' : '') + '>Raw</option>'
        + '  <option value="lpr"' + (p.protocol === 'lpr' ? ' selected' : '') + '>LPR</option>'
        + '</select>'
        + portField
        + '<input type="text" value="' + esc(p.ppd) + '" placeholder="generic or /path/to/file.ppd" oninput="updatePrinter(' + i + ',\'ppd\',this.value)">';
    }

    row.innerHTML = badge + '<div class="printer-fields">' + fields + '</div>'
      + '<button class="item-remove" onclick="removePrinter(' + i + ')" title="Remove">&times;</button>';
    list.appendChild(row);
  });
}
```

- [ ] **Step 4: Add CSS for printer badges and layout**

In the `{% block extra_styles %}`:
```css
.printer-badge {
  font-family: var(--mono);
  font-size: 10px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 4px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  flex-shrink: 0;
}
.printer-badge.dre {
  background: var(--accent-dim);
  color: var(--accent);
  border: 1px solid var(--accent);
}
.printer-badge.ip {
  background: var(--green-dim, rgba(52,199,89,0.1));
  color: var(--green, #34c759);
  border: 1px solid var(--green, #34c759);
}
.printer-fields {
  display: flex;
  gap: 0.5rem;
  flex: 1;
  flex-wrap: wrap;
}
.printer-fields input,
.printer-fields select {
  flex: 1;
  min-width: 120px;
}
.printer-item {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.5rem 0;
  border-bottom: 1px solid var(--border);
}
.printer-item:last-child { border-bottom: none; }
.printer-add-buttons {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
.empty-state {
  color: var(--text-muted);
  font-size: 0.85rem;
  padding: 1rem 0;
  text-align: center;
}
```

- [ ] **Step 5: Verify Step 3**

Run the dev server. Navigate to Step 3 (Printers). Verify:
- Empty state shows "No printers added."
- "New Printer (DRE)" adds a DRE row with name + PPD fields and DRE badge
- "New IP Printer" adds an IP row with IP, name, protocol, port/queue, PPD fields and IP badge
- Switching protocol between Raw/LPR shows port vs queue field
- Remove button works
- DRE Server validation only triggers when DRE printers exist

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "feat: build Equitrac Step 3 (Printers) with DRE and IP printer support"
```

---

## Chunk 3: XML Generation & Steps 4-6 (Packages, Build, Deploy)

### Task 5: Update buildXML() to include all new config keys

**Note:** This must be done BEFORE wiring up the Build/Deploy sections, since those sections call `buildXML()` and `generateProfile()` which need to reference the new DOM elements (radio groups, checkboxes) from Tasks 2-4. Also remove the dead `updateBitmask()` function and unify toggle handling.

**Files:**
- Modify: `app/templates/tools/equitrac.html`

- [ ] **Step 1: Update buildXML() to read new fields**

Add these reads at the top of `buildXML()`:

```javascript
var installDrc = document.getElementById('installDrc').checked;
var drcSysNameMode = document.querySelector('input[name="drcMode"]:checked').value;
var skipLinkLocal = document.getElementById('skipLinkLocal').checked;
var ipAddrInterface = document.getElementById('ipAddrInterface').value;
var regDns = document.getElementById('regDns').checked;
var cacheLogin = document.getElementById('cacheLogin').checked;
var promptPassword = document.getElementById('promptPassword').checked;
var userIdLabel = document.getElementById('userIdLabel').value.trim();
var ignoreCC = document.getElementById('ignoreCC').checked;
```

- [ ] **Step 2: Update the XML template string**

After the existing `PREF_RELEASE_KEY` key/value, add the new keys:

```javascript
+ '\t\t\t\t\t\t\t<key>SKIP_LINK_LOCAL_IP</key>\n'
+ '\t\t\t\t\t\t\t' + boolTag(skipLinkLocal) + '\n'
+ '\t\t\t\t\t\t\t<key>IP_ADDR_INTERFACE</key>\n'
+ '\t\t\t\t\t\t\t<string>' + xmlEsc(ipAddrInterface) + '</string>\n'
+ '\t\t\t\t\t\t\t<key>REG_MACHINE_ID_DNS</key>\n'
+ '\t\t\t\t\t\t\t' + boolTag(regDns) + '\n'
+ '\t\t\t\t\t\t\t<key>USE_CACHED_LOGIN</key>\n'
+ '\t\t\t\t\t\t\t' + boolTag(cacheLogin) + '\n'
+ '\t\t\t\t\t\t\t<key>PROMPT_FOR_PASSWORD</key>\n'
+ '\t\t\t\t\t\t\t' + boolTag(promptPassword) + '\n'
+ '\t\t\t\t\t\t\t<key>USER_ID_LABEL</key>\n'
+ '\t\t\t\t\t\t\t<string>' + xmlEsc(userIdLabel) + '</string>\n'
+ '\t\t\t\t\t\t\t<key>IGNORE_SUPPLIES_LEVEL_JOB</key>\n'
+ '\t\t\t\t\t\t\t' + boolTag(ignoreCC) + '\n'
```

Also update the `installDrc` read to use checkbox instead of select, and `drcSysNameMode` to use the radio group.

- [ ] **Step 3: Update printer XML generation for mixed types**

Replace the existing `printerXml` builder with one that handles both types:

```javascript
var livePrinters = printers.filter(function(p) { return p.name; });
var printerXml = livePrinters.map(function(p) {
  var xml = '\t\t\t\t\t\t\t\t<dict>\n';
  xml += '\t\t\t\t\t\t\t\t\t<key>type</key>\n';
  xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.type) + '</string>\n';
  xml += '\t\t\t\t\t\t\t\t\t<key>name</key>\n';
  xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.name) + '</string>\n';
  xml += '\t\t\t\t\t\t\t\t\t<key>ppd</key>\n';
  xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.ppd || 'generic') + '</string>\n';
  if (p.type === 'ip') {
    xml += '\t\t\t\t\t\t\t\t\t<key>ip</key>\n';
    xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.ip) + '</string>\n';
    xml += '\t\t\t\t\t\t\t\t\t<key>protocol</key>\n';
    xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.protocol) + '</string>\n';
    if (p.protocol === 'raw') {
      xml += '\t\t\t\t\t\t\t\t\t<key>port</key>\n';
      xml += '\t\t\t\t\t\t\t\t\t<integer>' + parseInt(p.port || '9100', 10) + '</integer>\n';
    } else {
      xml += '\t\t\t\t\t\t\t\t\t<key>queue</key>\n';
      xml += '\t\t\t\t\t\t\t\t\t<string>' + xmlEsc(p.queue) + '</string>\n';
    }
  }
  xml += '\t\t\t\t\t\t\t\t</dict>';
  return xml;
}).join('\n');
```

- [ ] **Step 4: Update the old validate() function**

Replace the monolithic `validate()` with calls to `validateCurrentStep()` for the deploy step. Update `generateProfile()`:

```javascript
function generateProfile() {
  var banner = document.getElementById('validationBanner');

  // Run all step validations
  var allOk = validateFields(['secDomain','secUsername','secPassword','secNode','datacenterName','casServer','installerPkgName']);
  var printerOk = validatePrinterStep();

  if (!allOk || !printerOk) {
    banner.classList.add('visible');
    document.getElementById('validationMsg').textContent =
      'Some required fields are empty. Check highlighted sections.';
    document.getElementById('xmlPreview').innerHTML =
      '<span style="color:var(--danger)">Fix validation errors before generating.</span>';
    return;
  }

  banner.classList.remove('visible');
  var result = buildXML();
  var filename = result.bundleId + '.mobileconfig';
  document.getElementById('outputFilename').textContent = filename;
  document.getElementById('xmlPreview').innerHTML = highlight(result.xml);
  markSaved();
  window._lastXml = result.xml;
  window._lastFilename = filename;
}
```

- [ ] **Step 5: Verify XML output**

Run the dev server. Fill in all fields across all steps. Generate the profile. Verify:
- All new keys appear in the mobileconfig XML
- DRE printers have `type`, `name`, `ppd` keys
- IP printers additionally have `ip`, `protocol`, and `port` or `queue`
- Boolean values render as `<true/>` or `<false/>`
- String values are XML-escaped

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "feat: update Equitrac buildXML with new config keys and mixed printer types"
```

---

### Task 6: Build Steps 4-6 and wire up remaining sections

**Files:**
- Modify: `app/templates/tools/equitrac.html`

- [ ] **Step 1: Rename s-drivers to s-packages**

Change the section ID from `s-drivers` to `s-packages`. Update the section tag to "04 / Packages". Keep the existing card structure for installer PKG and driver list. Update the section footer buttons to use `prevStep()`/`nextStep()`.

- [ ] **Step 2: Update s-build section**

Change section tag to "05 / Build". Update footer buttons. The Build button on Step 4's Next should trigger `generateBuildScript()` before navigating:

```html
<button class="btn btn-primary" onclick="generateBuildScript(); nextStep()">Build Package &rarr;</button>
```

- [ ] **Step 3: Update s-deploy section**

Change ID from `s-generate` to `s-deploy`. Change section tag to "06 / Deploy". Update footer Back button to use `prevStep()`. The deploy section renders on entry — update the Next button in Step 5 to trigger `generateProfile()`:

```html
<!-- In s-build footer -->
<button class="btn btn-primary" onclick="generateProfile(); nextStep()">Deploy &rarr;</button>
```

- [ ] **Step 4: Remove the old s-servers and s-features sections**

Delete the `s-servers` and `s-features` section divs entirely — their content has been moved to `s-enrollment` and `s-preferences`.

- [ ] **Step 5: Verify Steps 4-6**

Run the dev server. Navigate through all 6 steps. Verify:
- Packages section shows installer and drivers fields
- Build generates and displays the script
- Deploy generates and displays the mobileconfig XML with all new keys
- Back/Next navigation works through all 6 steps
- Stepper dots update correctly (completed = green check, active = accent glow)

- [ ] **Step 6: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "feat: complete Equitrac Steps 4-6 (Packages, Build, Deploy)"
```

---

## Chunk 4: Postinstall Script Updates

### Task 7: Update postinstall script to read new config keys

**Files:**
- Modify: `scripts/equitrac_postinstall.sh`

- [ ] **Step 1: Add new config variable reads with normalization**

After the existing `DRC_SYS_NAME_MODE` read (near the top of the script), add reads for the new keys. Note: `defaults read` returns `1`/`0` for booleans in plists, so we must normalize to `true`/`false` strings since EquitracOfficePrefs uses those string values.

```bash
# Read new prefs from config profile
SKIP_LINK_LOCAL_IP=$(defaults read "${PLIST_PATH}" SKIP_LINK_LOCAL_IP 2>/dev/null || echo true)
IP_ADDR_INTERFACE=$(defaults read "${PLIST_PATH}" IP_ADDR_INTERFACE 2>/dev/null || echo "")
REG_MACHINE_ID_DNS=$(defaults read "${PLIST_PATH}" REG_MACHINE_ID_DNS 2>/dev/null || echo false)
USE_CACHED_LOGIN=$(defaults read "${PLIST_PATH}" USE_CACHED_LOGIN 2>/dev/null || echo false)
PROMPT_FOR_PASSWORD=$(defaults read "${PLIST_PATH}" PROMPT_FOR_PASSWORD 2>/dev/null || echo true)
USER_ID_LABEL=$(defaults read "${PLIST_PATH}" USER_ID_LABEL 2>/dev/null || echo "")
IGNORE_SUPPLIES_LEVEL_JOB=$(defaults read "${PLIST_PATH}" IGNORE_SUPPLIES_LEVEL_JOB 2>/dev/null || echo false)

# Normalize booleans (defaults read returns 1/0 for plist booleans)
for _bvar in SKIP_LINK_LOCAL_IP REG_MACHINE_ID_DNS USE_CACHED_LOGIN PROMPT_FOR_PASSWORD IGNORE_SUPPLIES_LEVEL_JOB; do
    case "${!_bvar,,}" in
        1|true|yes) printf -v "$_bvar" '%s' "true" ;;
        *)          printf -v "$_bvar" '%s' "false" ;;
    esac
done
```

- [ ] **Step 2: Update create_config_files() to use config values instead of hardcoded**

In the `create_config_files()` function, replace the hardcoded `EquitracOfficePrefs` heredoc. Change lines 329-343 to read from variables:

```bash
cat > "$base_dir/EquitracOfficePrefs" <<EOF
DNSMachineID = ${hostname_fqdn}
DRCSysNameMode = ${DRC_SYS_NAME_MODE}
Feature Selection = ${FEATURE_SELECTION}
IPAddrInterfaceName = ${IP_ADDR_INTERFACE}
IgnoreSuppliesLevelJob = ${IGNORE_SUPPLIES_LEVEL_JOB}
LastCASSync = $(date +%s)
LastModifiedTimestamp = $(date '+%Y-%m-%d %H:%M:%S')
LastPrinterCacheFullUpdate = $(date +%s)
PromptForPasssword = ${PROMPT_FOR_PASSWORD}
RegMachineIDWithDNSSvr = ${REG_MACHINE_ID_DNS}
SkipLinkLocalIPAddr = ${SKIP_LINK_LOCAL_IP}
UseCachedLogin = ${USE_CACHED_LOGIN}
UserIDLabelText = ${USER_ID_LABEL}
EOF
```

- [ ] **Step 3: Commit**

```bash
git add scripts/equitrac_postinstall.sh
git commit -m "feat: read new EQPrinterUtilityX prefs from config profile in postinstall"
```

---

### Task 8: Update postinstall script to handle mixed printer types

**Files:**
- Modify: `scripts/equitrac_postinstall.sh`

- [ ] **Step 1: Update load_printer_config() to read printer type and IP fields**

Add new parallel arrays after the existing `PRINTER_NAMES` and `PRINTER_PPDS`:

```bash
PRINTER_TYPES=()     # parallel array: "dre" or "ip"
PRINTER_IPS=()       # parallel array: IP address (IP printers only, empty for DRE)
PRINTER_PROTOCOLS=() # parallel array: "raw" or "lpr" (IP printers only, empty for DRE)
PRINTER_PORTS=()     # parallel array: port number (IP+raw only, empty otherwise)
PRINTER_QUEUES=()    # parallel array: queue name (IP+lpr only, empty otherwise)
```

In the `load_printer_config()` loop (inside the `for (( i = 0; i < printer_count; i++ ))` block), after reading `name` and `ppd`, add:

```bash
local ptype
ptype=$("$pb" -c "Print :PRINTERS:${i}:type" "$PLIST_PATH" 2>/dev/null || echo "dre")
PRINTER_TYPES+=( "$ptype" )

if [[ "$ptype" == "ip" ]]; then
    local pip pproto pport pqueue
    pip=$("$pb" -c "Print :PRINTERS:${i}:ip" "$PLIST_PATH" 2>/dev/null || echo "")
    pproto=$("$pb" -c "Print :PRINTERS:${i}:protocol" "$PLIST_PATH" 2>/dev/null || echo "raw")
    pport=$("$pb" -c "Print :PRINTERS:${i}:port" "$PLIST_PATH" 2>/dev/null || echo "9100")
    pqueue=$("$pb" -c "Print :PRINTERS:${i}:queue" "$PLIST_PATH" 2>/dev/null || echo "")
    PRINTER_IPS+=( "$pip" )
    PRINTER_PROTOCOLS+=( "$pproto" )
    PRINTER_PORTS+=( "$pport" )
    PRINTER_QUEUES+=( "$pqueue" )
    log_info "  Printer[$i]: type=ip name='$name' ip='$pip' proto='$pproto' port='$pport' queue='$pqueue' ppd='$ppd'"
else
    PRINTER_IPS+=( "" )
    PRINTER_PROTOCOLS+=( "" )
    PRINTER_PORTS+=( "" )
    PRINTER_QUEUES+=( "" )
    log_info "  Printer[$i]: type=dre name='$name' ppd='$ppd'"
fi
```

- [ ] **Step 2: Update create_printers() to build URIs based on type**

In the `create_printers()` function, inside the `for (( i = 0; ... ))` loop, replace the existing `device_uri` line:

```bash
local printer_type="${PRINTER_TYPES[$i]}"
local device_uri=""

if [[ "$printer_type" == "ip" ]]; then
    local pip="${PRINTER_IPS[$i]}"
    local pproto="${PRINTER_PROTOCOLS[$i]}"
    if [[ "$pproto" == "lpr" ]]; then
        local pqueue="${PRINTER_QUEUES[$i]}"
        device_uri="lpd://${pip}/${pqueue}"
    else
        local pport="${PRINTER_PORTS[$i]:-9100}"
        device_uri="socket://${pip}:${pport}"
    fi
else
    # DRE printer -- use eqtrans backend (or lpd fallback)
    device_uri="${backend}://${DRE_SERVER}/${printer_name}"
fi
```

Note: The `backend` variable (eqtrans with lpd fallback) only applies to DRE printers. IP printers always use their explicit protocol.

- [ ] **Step 3: Verify no syntax errors**

```bash
bash -n scripts/equitrac_postinstall.sh
```

Expected: no output (clean parse).

- [ ] **Step 4: Commit**

```bash
git add scripts/equitrac_postinstall.sh
git commit -m "feat: handle mixed DRE and IP printer types in postinstall script"
```

---

## Chunk 5: Cleanup & Final Verification

### Task 9: Clean up old code and verify end-to-end

**Files:**
- Modify: `app/templates/tools/equitrac.html`

- [ ] **Step 1: Remove dead code**

Remove any leftover references to the old section IDs (`s-security`, `s-servers`, `s-features`, `s-generate`), the old `navigate()` function, old `navLink()` function, and the `SECTIONS` constant. Remove the old `#sideNav` CSS if any exists in the template.

- [ ] **Step 2: Clean up state initialization**

Ensure the init block at the bottom of the script calls:
```javascript
renderPrinters();
renderDrivers();
updateDrcVisibility();
updateDrcMode();
```

- [ ] **Step 3: End-to-end verification**

Run `python run.py` and test the full flow:
1. Step 1: Paste an enrollment command → all fields populate, DRC toggle updates
2. Step 1: Click Next → validates required fields
3. Step 2: Toggle features, set CAS Server, configure DRC options, login options
4. Step 2: Enable DRC in Step 1 → DRC System Name card appears in Step 2
5. Step 3: Add a DRE printer and an IP printer (both Raw and LPR)
6. Step 3: DRE Server only required when DRE printers exist
7. Step 4: Set installer PKG name, add a driver
8. Step 5: Build script generates correctly
9. Step 6: Mobileconfig XML contains all new keys, both printer types
10. Stepper navigation: dots update, can click completed steps to go back

- [ ] **Step 4: Commit**

```bash
git add app/templates/tools/equitrac.html
git commit -m "refactor: clean up old Equitrac navigation code and verify end-to-end"
```

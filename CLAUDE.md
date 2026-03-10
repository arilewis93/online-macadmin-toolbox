# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

### Flask Web App
```bash
python run.py                    # Dev server on http://localhost:5001
```
Requires `.env` with OIDC credentials (see `.env.example`). Port configurable via `PORT` env var.

### Swift Agent (macOS companion app)
```bash
cd agent && swift build          # Debug build
cd agent && ./build_and_sign.sh  # Signed release .app bundle
```
The agent binary registers the `macadmin-toolbox://` URL scheme and listens on port 8765.

### Dependencies
```bash
pip install -r requirements.txt  # Flask, Flask-Login, Flask-WTF, requests, python-dotenv, gunicorn
```

### No Tests
There are no test suites in this project.

## Architecture

**Flask web app** serving browser-based Mac admin tools, with a **native Swift macOS agent** for privileged local operations.

### Web App (`app/`)

- **Factory pattern**: `app/__init__.py` creates the Flask app, registers blueprints (`auth`, `main`), initializes Flask-Login and CSRF
- **Session-only auth**: OIDC with Microsoft Entra ID — no database, user stored in Flask session only
- **Generic tool routing**: `app/views/main.py` has a single `/<tool_name>` route that renders `tools/{tool_name}.html` for any name in the `TOOL_NAMES` set. To add a tool: add name to `TOOL_NAMES`, create the template, add a dashboard card
- **Mac-only gating**: Tools requiring the local agent (`auto_configurator`, `intune_*`, `dmg_packager`) are 404'd for non-macOS user agents
- **CORS proxies**: Flask proxies S3 file downloads and Azure Blob uploads to avoid browser CORS restrictions

### Tool Templates (`app/templates/tools/`)

Each tool is a self-contained HTML template extending `base.html` with inline `<script>`. Shared utilities come from `_shared_utils.html` (UUID generation, plist building, XML escaping, file download, toggle helpers). Styling uses `app/static/css/tools.css` with CSS variables for dark theme.

**Tool categories**:
- **Client-side only** (Santa, SmartBranding, Bookmarks, etc.): Generate `.mobileconfig` profiles or scripts entirely in the browser
- **Intune/Graph API** (intune_base_build, serial_killer, etc.): Use the agent for Microsoft Graph auth, then call Graph API directly from browser JS via `app/static/js/intune-graph-client.js`
- **Agent-dependent** (auto_configurator, dmg_packager): Trigger agent via `macadmin-toolbox://` URL scheme, poll `http://127.0.0.1:8765` for results

### Swift Agent (`agent/Sources/MacAdminToolbox/main.swift`)

Single-file macOS app (no frameworks beyond Foundation/AppKit/Network/SQLite3). Handles:
- **URL scheme dispatch**: `AppDelegate.application(_:open:)` routes `macadmin-toolbox://{action}` to handlers
- **TCC database reading**: Reads `/Library/Application Support/com.apple.TCC/TCC.db` (requires Full Disk Access)
- **HTTP server on port 8765**: NWListener-based, serves JSON responses with CORS headers
- **Two server patterns**: (1) One-shot — serve result then terminate (TCC fetch), (2) Persistent — stay alive for multiple requests (Intune auth, DMG packager)
- **Intune auth**: Manages a persistent PowerShell session for `Connect-MgGraph` token relay

### Adding a New Tool

1. Add tool name to `TOOL_NAMES` in `app/views/main.py`
2. If Mac-only, add to the platform gate condition on the same file
3. Create `app/templates/tools/{tool_name}.html` extending `base.html`
4. Add a card in `app/templates/dashboard.html` under the appropriate category
5. If agent interaction needed: add URL scheme handler in `main.swift` AppDelegate

### Key Conventions

- Tool templates use `var` (not `let`/`const`) for broad browser compatibility
- Agent communication: browser opens `macadmin-toolbox://` URL via hidden iframe, then polls HTTP endpoint
- Plist/mobileconfig generation happens client-side via `toPlist()` / `buildPlistDoc()` from shared utils
- All API proxy routes require `@login_required`; the Azure blob proxy is `@csrf.exempt`

## Deployment

Production deploys to Render.com via `render.yaml`. Build: `pip install -r requirements.txt`. Start: `gunicorn run:app`.

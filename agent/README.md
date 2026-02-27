# Auto Configurator agent (macOS)

Small native app used by the [Auto Configurator](https://github.com/your-org/online-macadmin-toolbox) web tool. When you drop an app in the browser, the page opens this agent with the app’s bundle ID prefix; the agent reads TCC (Full Disk Access, etc.) and serves the result so the page can show and edit permissions.

## Build

```bash
cd agent
./build_app.sh
```

Creates `AutoConfigAgent.app` in this directory.

## Install

1. Move `AutoConfigAgent.app` to `/Applications` (or keep it anywhere).
2. Grant **Full Disk Access** in **System Settings → Privacy & Security → Full Disk Access** so it can read the TCC database.
3. No need to “run” it manually—the browser launches it when you drop an app in the Auto Configurator tool.

## How it works

- The app registers the URL scheme `macadmin-toolbox://`.
- The web page opens e.g. `macadmin-toolbox://fetch-tcc?search=com.example.`
- The agent reads `/Library/Application Support/com.apple.TCC/TCC.db`, filters by that search term, runs `codesign` to get identifiers and code requirements, then starts a short-lived HTTP server on port **8765**.
- The page polls `http://127.0.0.1:8765/result` and receives JSON with the permission entries.
- The agent quits after sending the response or after 60 seconds.

## Requirements

- macOS 10.15+
- Xcode Command Line Tools (`xcode-select --install`)

## Contract

See [../docs/auto-configurator-mac-agent.md](../docs/auto-configurator-mac-agent.md) for the JSON format and behaviour expected by the web UI.

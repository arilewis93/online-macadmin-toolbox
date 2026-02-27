# Auto Configurator — Mac agent contract

The web UI cannot read the TCC database or run `codesign` on the Mac. A small **Mac agent** (app or script) runs locally with Full Disk Access and provides:

1. **URL scheme** (optional): handle `macadmin-toolbox://fetch-tcc?search=SEARCH_TERM`
   - `search` = URL-encoded search term (e.g. `com.example.` from the dropped app’s bundle ID).
   - When opened, the agent should run the TCC/fetch logic (see full_toolbox.py Auto Configurator) and then serve the result so the page can poll for it.

2. **Callback (optional)**  
   - After fetching TCC data, the agent starts a short-lived HTTP server on **localhost** (default port **8765**).
   - The webpage will poll `GET http://127.0.0.1:PORT/result` (CORS must allow the page’s origin or `*`).
   - Respond with **JSON** in the format below.

3. **JSON response format**  
   The page expects an object with an `entries` array. Each entry:

   - `path_or_label` (string): display path or app name (e.g. `/Applications/MyApp.app` or `MyApp`).
   - `identifier` (string): bundle ID (e.g. `com.example.MyApp`).
   - `code_requirement` (string): full line from `codesign -dr - /path/to/App.app`.
   - `permissions` (array of strings): TCC profile keys, e.g. `["SystemPolicyAllFiles", "Accessibility"]`.

   Example:

   ```json
   {
     "search_term": "com.example.",
     "entries": [
       {
         "path_or_label": "/Applications/MyApp.app",
         "identifier": "com.example.MyApp",
         "code_requirement": "identifier \"com.example.MyApp\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* ... */",
         "permissions": ["SystemPolicyAllFiles", "Accessibility"]
       }
     ]
   }
   ```

4. **Alternative: paste JSON**  
   If the agent does not use the URL scheme or local server, the user can run the agent manually, copy its JSON output, and paste it into the “Or paste JSON from Mac agent” textarea, then click **Apply**.

## TCC profile key names (Services)

Use the same keys as in `full_toolbox.py` → `TCC_PROFILE_KEY_DISPLAY_NAMES`, e.g.:

- `SystemPolicyAllFiles` (Full Disk Access)
- `Accessibility`
- `ScreenCapture`
- `AppleEvents`
- `Camera`, `Microphone`, `Photos`, etc.

## Reference implementation

The logic to replicate from `Mac-Admin-Toolbox/full_toolbox.py`:

- `_auto_config_fetch_tcc_by_bundle_id(search_term)` → paths, `tcc_services`, `path_to_services`.
- For each path: get identifier and code requirement via `codesign -dr - PATH`.
- Map TCC DB service names to profile keys (`kTCCServiceSystemPolicyAllFiles` → `SystemPolicyAllFiles`).
- Output the `entries` array in the JSON shape above (one entry per path, with that path’s permissions list).

# Online MacAdmin Toolbox

A Flask web app for Mac admins: **Microsoft Entra ID** (Azure AD) sign-in plus a set of tools to generate configuration profiles and scripts. Built on a shared dark UI and a single dashboard.

## Features

- **Microsoft Entra ID (OIDC)** sign-in with session-based auth (Flask-Login)
- **Dashboard** — signed-in home with quick links to each tool
- **iStore Business Toolbox** — SwiftSetup, SmartBranding, Favourite Bookie, Santa Config, Profile Fusion, Patchy Installer, Compliance Fixer
- **Equitrac** — config profile generator for Equitrac Mac Client (security, servers, printers, drivers, feature flags)
- **Shared layout** — one header, one stylesheet (`tools.css`), tool pages inject their own left-side branding

## Quick start

```bash
git clone https://github.com/arilewis93/online-macadmin-toolbox.git
cd online-macadmin-toolbox
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your Entra app credentials (see below)
export FLASK_APP=run.py
flask run
# or: python run.py  (default port 5001)
```

Visit `http://localhost:5001` → Sign in with Microsoft → Dashboard → open Toolbox or Equitrac.

## Deploy on Render.com

1. **Push this repo to GitHub** (or connect an existing repo).
2. In **[Render Dashboard](https://dashboard.render.com)** → **New** → **Blueprint**. Connect the repo; Render will read `render.yaml` and create the Web Service.
   - Or **New** → **Web Service**, select the repo, then set:
     - **Build Command**: `pip install -r requirements.txt`
     - **Start Command**: `gunicorn run:app -b 0.0.0.0:$PORT`
3. **Environment**: In the service → **Environment**, set:
   - `SECRET_KEY` — use the auto-generated value from the Blueprint, or generate your own.
   - `OIDC_AUTHORITY` — e.g. `https://login.microsoftonline.com/{tenant-id}`.
   - `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` — from your Entra app registration.
   - `OIDC_REDIRECT_URI` — **must be your Render URL**, e.g. `https://online-macadmin-toolbox.onrender.com/auth/oidc/callback`.
4. **Entra**: In Azure, add the Render callback URL above as a **Redirect URI** (Web) for your app registration.
5. **Database (optional)**: For production, add a **PostgreSQL** instance in Render, then in the Web Service add `DATABASE_URL` with the database’s **Internal Database URL**. Without it, the app uses SQLite (ephemeral on Render; data is lost on deploy).

After the first deploy, open your service URL and sign in with Microsoft.

## Entra ID app registration

1. **Azure Portal** → **Microsoft Entra ID** → **App registrations** → **New registration**.
2. **Name**: e.g. "MacAdmin Toolbox". Set **Supported account types** as needed.
3. **Redirect URI**: Web → `http://localhost:5001/auth/oidc/callback` (dev) or your production URL. Must match `OIDC_REDIRECT_URI` exactly.
4. **Certificates & secrets** → New client secret → copy into `OIDC_CLIENT_SECRET`.
5. **Overview** → **Application (client) ID** → `OIDC_CLIENT_ID`; **Directory (tenant) ID** → use in `OIDC_AUTHORITY` or set `ENTRA_TENANT_ID`.
6. **API permissions** → Add → Microsoft Graph → Delegated → `openid`, `User.Read` (and `email`, `profile` if needed). Grant admin consent if required.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SECRET_KEY` | Yes | Flask secret key (sessions). |
| `OIDC_AUTHORITY` | Yes* | Authority URL, e.g. `https://login.microsoftonline.com/{tenant-id}`. |
| `ENTRA_TENANT_ID` | Yes* | Tenant ID; used to build authority if `OIDC_AUTHORITY` is not set. |
| `OIDC_CLIENT_ID` | Yes | Application (client) ID from app registration. |
| `OIDC_CLIENT_SECRET` | Yes | Client secret value. |
| `OIDC_REDIRECT_URI` | Yes | Redirect URI, e.g. `http://localhost:5001/auth/oidc/callback`. Must match Entra. |
| `OIDC_SCOPE` | No | Scopes (default: `openid profile email`). |
| `DATABASE_URL` | No | DB URL (default: SQLite `sqlite:///app.db`). |

\* Set either `OIDC_AUTHORITY` or `ENTRA_TENANT_ID`.

## Project layout

```
online-macadmin-toolbox/
├── README.md
├── requirements.txt
├── render.yaml          # Render.com Blueprint (build/start + env)
├── .env.example
├── run.py
├── config.py
└── app/
    ├── __init__.py
    ├── models/
    │   └── user.py
    ├── utils/
    │   └── oidc.py
    ├── views/
    │   ├── auth.py
    │   └── main.py
    ├── static/
    │   └── css/
    │       └── tools.css
    └── templates/
        ├── base.html
        ├── index.html
        ├── dashboard.html
        ├── auth/
        │   └── login.html
        └── tools/
            ├── toolbox.html
            └── equitrac.html
```

## Routes

| Route | Description |
|-------|-------------|
| `GET /` | Home; link to sign in or dashboard. |
| `GET /auth/login` | Login page; "Sign in with Microsoft" → OIDC. |
| `GET /auth/oidc/login` | Start OIDC flow (redirect to Entra). |
| `GET /auth/oidc/callback` | OIDC callback; exchange code, create/update user, log in. |
| `GET /auth/logout` | Log out. |
| `GET /dashboard` | Protected dashboard; links to Toolbox and Equitrac. |
| `GET /toolbox` | iStore Business Toolbox (SwiftSetup, SmartBranding, etc.). |
| `GET /equitrac` | Equitrac config profile generator. |

## Tools

- **Toolbox** (`/toolbox`) — SwiftSetup (.mobileconfig), SmartBranding (wallpaper/screensaver), Favourite Bookie (Chrome/Edge bookmarks), Santa Config, Profile Fusion (merge .mobileconfig), Patchy Installer (Installomator labels), Compliance Fixer (script patching). Apps to install support drag-and-drop reorder and, for Installomator, a label picklist from [Installomator Labels.txt](https://github.com/Installomator/Installomator/blob/main/Labels.txt).
- **Equitrac** (`/equitrac`) — Multi-step form to build an Apple Configuration Profile for Equitrac Mac Client (security, CAS/DRE servers, printers, drivers, feature flags), then generate and download the `.mobileconfig`.

## License

Use and adapt as needed; Entra/OIDC flow is based on patterns from the SwiftSetup.cloud codebase.

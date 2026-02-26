# Entra ID (Azure AD) Auth Template

Minimal Flask app with **Microsoft Entra ID** (Azure AD) OpenID Connect authentication. Use this as a starting point whenever you need Entra-based auth in a new project.

## Features

- **OIDC authorization code flow** with Entra ID
- **Discovery** from `https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration`
- **State parameter** for CSRF protection; 10-minute expiry
- **Silent auth** attempt first (`prompt=none`), fallback to interactive login
- **Session-based** login via Flask-Login; single `User` model with `oidc_id`, `email`, `name`
- Config from **environment variables** (no tenant/DB config in template)

## Quick start

```bash
cd entra-auth-template
python -m venv .venv
source .venv/bin/activate   # or .venv\Scripts\activate on Windows
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your Entra app credentials
export FLASK_APP=run.py   # or set in .env: FLASK_APP=run.py
python run.py
# or: flask run
```

Visit `http://localhost:5000` → Sign in → redirects to Entra → callback → dashboard.

## Entra ID app registration

1. **Azure Portal** → **Microsoft Entra ID** → **App registrations** → **New registration**.
2. **Name**: e.g. "My App".
3. **Supported account types**: "Accounts in this organizational directory only" (single tenant) or as needed.
4. **Redirect URI**: Web, e.g. `http://localhost:5000/auth/oidc/callback` (dev) or your production URL. Must match `OIDC_REDIRECT_URI` exactly.
5. **Certificates & secrets** → New client secret → copy value into `OIDC_CLIENT_SECRET`.
6. **Overview** → copy **Application (client) ID** → `OIDC_CLIENT_ID`, **Directory (tenant) ID** → use for `ENTRA_TENANT_ID` or in authority URL.
7. **API permissions** → Add → Microsoft Graph → Delegated → `openid`, `User.Read` (or add `email`, `profile` if needed). Grant admin consent if required.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SECRET_KEY` | Yes | Flask secret key (sessions, CSRF). |
| `OIDC_AUTHORITY` | Yes* | Full authority URL, e.g. `https://login.microsoftonline.com/{tenant-id}`. |
| `ENTRA_TENANT_ID` | Yes* | Tenant ID; used to build authority if `OIDC_AUTHORITY` is not set. |
| `OIDC_CLIENT_ID` | Yes | Application (client) ID from app registration. |
| `OIDC_CLIENT_SECRET` | Yes | Client secret value. |
| `OIDC_REDIRECT_URI` | Yes | Redirect URI, e.g. `http://localhost:5000/auth/oidc/callback`. Must match Entra registration. |
| `OIDC_SCOPE` | No | Scopes (default: `openid profile email`). |
| `DATABASE_URL` | No | DB URL (default: SQLite `sqlite:///app.db`). |

\* Set either `OIDC_AUTHORITY` or `ENTRA_TENANT_ID`. If both are set, `OIDC_AUTHORITY` is used.

## Project layout

```
entra-auth-template/
├── README.md
├── requirements.txt
├── .env.example
├── run.py
├── config.py
└── app/
    ├── __init__.py      # create_app, db, login_manager
    ├── models/
    │   └── user.py      # User (oidc_id, email, name)
    ├── utils/
    │   └── oidc.py      # discovery, token exchange, userinfo
    ├── views/
    │   ├── auth.py      # /auth/login, /auth/oidc/*, /auth/logout
    │   └── main.py      # /, /dashboard
    └── templates/
        ├── base.html
        ├── auth/
        │   └── login.html
        ├── index.html
        └── dashboard.html
```

## Routes

| Route | Description |
|-------|-------------|
| `GET /` | Home; link to login or dashboard. |
| `GET /auth/login` | Login page; "Sign in with Microsoft" → OIDC. |
| `GET /auth/oidc/login` | Start OIDC flow (redirect to Entra). |
| `GET /auth/oidc/callback` | OIDC callback; exchange code, create/update user, log in. |
| `GET /auth/logout` | Log out (app session only). |
| `GET /dashboard` | Protected dashboard (requires login). |

## Extending

- **Multi-tenant**: Add a `Tenant` (and optionally `TenantDomain`) model and store OIDC config per tenant; in auth, resolve tenant from domain or path and use the matching config.
- **Encrypt client secret**: Store secret in DB and use an encryption layer (e.g. `cryptography`) with a key from env or a key manager.
- **Roles**: Add a `Role` / `UserRole` model and protect routes by permission.
- **HTTPS / production**: Set `ENFORCE_HTTPS=true`, use a proper WSGI server (e.g. Gunicorn), and set `OIDC_REDIRECT_URI` to your production callback URL.

## Reference

Based on the Entra/OIDC implementation in the SwiftSetup.cloud codebase (Flask, discovery, code exchange, userinfo, session login).

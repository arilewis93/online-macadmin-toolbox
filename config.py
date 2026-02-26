"""Configuration from environment."""
import os
from dotenv import load_dotenv

load_dotenv()


def get_oidc_authority():
    """OIDC authority URL: OIDC_AUTHORITY or built from ENTRA_TENANT_ID."""
    authority = os.environ.get("OIDC_AUTHORITY", "").strip()
    if authority:
        return authority.rstrip("/")
    tenant_id = os.environ.get("ENTRA_TENANT_ID", "").strip()
    if tenant_id:
        return f"https://login.microsoftonline.com/{tenant_id}"
    return ""


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY") or "dev-secret-change-in-production"
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL") or "sqlite:///app.db"
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    # OIDC / Entra
    OIDC_AUTHORITY = get_oidc_authority()
    ENTRA_TENANT_ID = os.environ.get("ENTRA_TENANT_ID", "")
    OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID", "")
    OIDC_CLIENT_SECRET = os.environ.get("OIDC_CLIENT_SECRET", "")
    OIDC_REDIRECT_URI = os.environ.get("OIDC_REDIRECT_URI", "")
    OIDC_SCOPE = os.environ.get("OIDC_SCOPE", "openid profile email")

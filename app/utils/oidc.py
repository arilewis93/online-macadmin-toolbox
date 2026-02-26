"""OIDC helpers: discovery, token exchange, userinfo."""
import requests
from flask import current_app


def get_oidc_discovery_document(authority):
    """Fetch OIDC discovery document from authority."""
    if not authority:
        return None
    base = authority.rstrip("/")
    candidates = [
        f"{base}/v2.0/.well-known/openid-configuration",
        f"{base}/.well-known/openid-configuration",
    ]
    for url in candidates:
        try:
            r = requests.get(url, timeout=10)
            r.raise_for_status()
            return r.json()
        except Exception as e:
            if current_app:
                current_app.logger.warning("OIDC discovery failed %s: %s", url, e)
    return None


def get_oidc_endpoints(authority):
    """Return authorization, token, userinfo endpoints from discovery."""
    discovery = get_oidc_discovery_document(authority)
    if not discovery:
        return None
    return {
        "authorization_endpoint": discovery.get("authorization_endpoint"),
        "token_endpoint": discovery.get("token_endpoint"),
        "userinfo_endpoint": discovery.get("userinfo_endpoint"),
        "jwks_uri": discovery.get("jwks_uri"),
    }


def exchange_code_for_tokens(code, redirect_uri, client_id, client_secret, authority):
    """Exchange authorization code for access token (and optional id_token)."""
    endpoints = get_oidc_endpoints(authority)
    if not endpoints or not endpoints.get("token_endpoint"):
        return None
    data = {
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }
    try:
        r = requests.post(endpoints["token_endpoint"], data=data, timeout=10)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        if current_app:
            current_app.logger.error("Token exchange failed: %s", e)
        return None


def get_user_info(access_token, authority):
    """Fetch userinfo from OIDC userinfo endpoint."""
    endpoints = get_oidc_endpoints(authority)
    if not endpoints or not endpoints.get("userinfo_endpoint"):
        return None
    headers = {"Authorization": f"Bearer {access_token}"}
    try:
        r = requests.get(
            endpoints["userinfo_endpoint"],
            headers=headers,
            timeout=10,
        )
        r.raise_for_status()
        return r.json()
    except Exception as e:
        if current_app:
            current_app.logger.error("Userinfo failed: %s", e)
        return None

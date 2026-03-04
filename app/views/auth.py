"""Auth routes: login, OIDC flow, logout."""
import os
from datetime import datetime, timezone
from urllib.parse import urlencode

from flask import Blueprint, request, redirect, url_for, session, current_app, flash
from flask_login import login_user, logout_user, login_required, current_user

from app.models.user import User
from app.utils.oidc import get_oidc_endpoints, exchange_code_for_tokens, get_user_info

auth = Blueprint("auth", __name__)


def _oidc_config():
    """Current OIDC config from app config (env)."""
    authority = current_app.config.get("OIDC_AUTHORITY") or (
        f"https://login.microsoftonline.com/{current_app.config.get('ENTRA_TENANT_ID', '')}"
        if current_app.config.get("ENTRA_TENANT_ID")
        else ""
    )
    return {
        "authority": authority,
        "client_id": current_app.config.get("OIDC_CLIENT_ID", ""),
        "client_secret": current_app.config.get("OIDC_CLIENT_SECRET", ""),
        "redirect_uri": current_app.config.get("OIDC_REDIRECT_URI", ""),
        "scope": current_app.config.get("OIDC_SCOPE", "openid profile email"),
    }


def _is_oidc_configured():
    c = _oidc_config()
    return bool(c["authority"] and c["client_id"] and c["client_secret"] and c["redirect_uri"])


@auth.route("/oidc/login")
def oidc_login():
    """Start interactive OIDC login flow."""
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    if not _is_oidc_configured():
        flash("OIDC is not configured.", "error")
        return redirect(url_for("main.index"))

    cfg = _oidc_config()
    endpoints = get_oidc_endpoints(cfg["authority"])
    if not endpoints or not endpoints.get("authorization_endpoint"):
        flash("Authentication provider unavailable.", "error")
        return redirect(url_for("main.index"))

    state = os.urandom(32).hex()
    session["oidc_state"] = state
    session["oidc_state_time"] = datetime.now(timezone.utc)

    params = {
        "client_id": cfg["client_id"],
        "response_type": "code",
        "scope": cfg["scope"],
        "redirect_uri": cfg["redirect_uri"],
        "state": state,
        "response_mode": "query",
    }
    auth_url = f"{endpoints['authorization_endpoint']}?{urlencode(params)}"
    return redirect(auth_url)


@auth.route("/oidc/callback")
def oidc_callback():
    """Handle OIDC callback: validate state, exchange code, create/update user, log in."""
    error = request.args.get("error")
    if error:
        current_app.logger.error("OIDC error: %s", request.args.get("error_description", error))
        flash("Authentication failed.", "error")
        return redirect(url_for("main.index"))

    state = request.args.get("state")
    stored_state = session.get("oidc_state")
    state_time = session.get("oidc_state_time")
    if not state or state != stored_state:
        flash("Invalid state parameter.", "error")
        return redirect(url_for("main.index"))
    if state_time:
        if (datetime.now(timezone.utc) - state_time).total_seconds() > 600:
            flash("State expired. Please try again.", "error")
            session.pop("oidc_state", None)
            session.pop("oidc_state_time", None)
            return redirect(url_for("main.index"))

    session.pop("oidc_state", None)
    session.pop("oidc_state_time", None)

    code = request.args.get("code")
    if not code:
        flash("Authorization code not received.", "error")
        return redirect(url_for("main.index"))

    cfg = _oidc_config()
    token_response = exchange_code_for_tokens(
        code,
        cfg["redirect_uri"],
        cfg["client_id"],
        cfg["client_secret"],
        cfg["authority"],
    )
    if not token_response:
        flash("Failed to exchange code for tokens.", "error")
        return redirect(url_for("main.index"))

    access_token = token_response.get("access_token")
    if not access_token:
        flash("No access token in response.", "error")
        return redirect(url_for("main.index"))

    user_info = get_user_info(access_token, cfg["authority"])
    if not user_info:
        flash("Failed to get user info.", "error")
        return redirect(url_for("main.index"))

    user = _user_from_userinfo(user_info)
    if not user:
        flash("Failed to get user info.", "error")
        return redirect(url_for("main.index"))

    session.clear()
    session["user_email"] = user.email
    session["user_name"] = user.name
    login_user(user)
    return redirect(url_for("main.dashboard"))


def _user_from_userinfo(user_info):
    """Build a User from OIDC userinfo (session-only, no DB)."""
    email = user_info.get("email") or user_info.get("preferred_username")
    name = user_info.get("name") or user_info.get("preferred_username", "Unknown")
    oidc_id = user_info.get("sub")
    if not email or not oidc_id:
        current_app.logger.error("OIDC userinfo missing email or sub")
        return None
    return User(id=oidc_id, email=email, name=name)


@auth.route("/logout")
@login_required
def logout():
    logout_user()
    try:
        session.clear()
    except Exception:
        pass
    return redirect(url_for("main.index"))

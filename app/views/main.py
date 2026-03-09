"""Main routes: index, dashboard."""
import requests as http_requests

from flask import Blueprint, abort, jsonify, redirect, render_template, request, url_for
from flask_login import login_required, current_user

main = Blueprint("main", __name__)

# Tool names that have their own page (dashboard links direct to these)
TOOL_NAMES = {
    "equitrac",
    "netskope",
    "santa",
    "swiftsetup",
    "smartbranding",
    "bookmarks",
    "fusion",
    "patchy",
    "compliance_fixer",
    "auto_configurator",
    "sentinelone_token",
    "intune_base_build",
}


# Substrings that indicate a non-macOS platform (exclude these first).
# Ref: MDN "Browser detection using the user agent", Windows/Android/iOS UA patterns.
_NON_MACOS_UA_SUBSTRINGS = (
    "windows nt",  # Windows (Chrome/Edge: "Windows NT 10.0", "Windows NT 11.0")
    "win32",
    "wow64",
    "win64",
    "android",     # Android (phones, tablets)
    "iphone",
    "ipad",        # iPad; iPadOS 13+ can send "Macintosh" so we must exclude "ipad" first
    "ipod",
    "cros",        # Chrome OS
    "linux",       # Linux desktop (macOS UA does not contain "linux")
)


def _is_mac_user_agent():
    """True only for macOS desktop. Excludes Windows, Android, iPhone, iPad, Chrome OS, Linux."""
    ua = (request.headers.get("User-Agent") or "").lower()
    if any(sub in ua for sub in _NON_MACOS_UA_SUBSTRINGS):
        return False
    return "macintosh" in ua


@main.route("/")
def index():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    return render_template("index.html")


@main.route("/dashboard")
@login_required
def dashboard():
    return render_template(
        "dashboard.html",
        user=current_user,
        show_auto_config=_is_mac_user_agent(),
    )


_S3_BASE = "https://narcp.s3.af-south-1.amazonaws.com/BaseBuildFiles/"


@main.route("/api/intune-file-list")
@login_required
def intune_file_list():
    """Proxy the S3 file list to avoid CORS issues."""
    try:
        resp = http_requests.get(_S3_BASE + "file_list.txt", timeout=10)
        resp.raise_for_status()
        files = [l.strip() for l in resp.text.splitlines() if l.strip()]
        return jsonify({"files": files, "base_url": _S3_BASE})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 502


@main.route("/<tool_name>")
@login_required
def toolbox(tool_name):
    if tool_name not in TOOL_NAMES:
        abort(404)
    if tool_name in ("auto_configurator", "intune_base_build") and not _is_mac_user_agent():
        abort(404)
    return render_template(f"tools/{tool_name}.html")

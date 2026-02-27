"""Main routes: index, dashboard."""
from flask import Blueprint, abort, render_template, request
from flask_login import login_required, current_user

main = Blueprint("main", __name__)

# Tool names that have their own page (dashboard links direct to these)
TOOL_NAMES = {
    "toolbox",
    "equitrac",
    "santa",
    "swiftsetup",
    "smartbranding",
    "bookmarks",
    "fusion",
    "patchy",
    "compliance_fixer",
    "auto_configurator",
}


def _is_mac_user_agent():
    """True if the request looks like it came from a Mac (macOS)."""
    ua = (request.headers.get("User-Agent") or "").lower()
    return "mac" in ua or "macintosh" in ua or "darwin" in ua or "os x" in ua


@main.route("/")
def index():
    return render_template("index.html")


@main.route("/dashboard")
@login_required
def dashboard():
    return render_template(
        "dashboard.html",
        user=current_user,
        show_auto_config=_is_mac_user_agent(),
    )


@main.route("/<tool_name>")
@login_required
def toolbox(tool_name):
    if tool_name not in TOOL_NAMES:
        abort(404)
    if tool_name == "auto_configurator" and not _is_mac_user_agent():
        abort(404)
    return render_template(f"tools/{tool_name}.html")

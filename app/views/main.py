"""Main routes: index, dashboard."""
from flask import Blueprint, abort, render_template
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
}


@main.route("/")
def index():
    return render_template("index.html")


@main.route("/dashboard")
@login_required
def dashboard():
    return render_template("dashboard.html", user=current_user)


@main.route("/<tool_name>")
@login_required
def toolbox(tool_name):
    if tool_name not in TOOL_NAMES:
        abort(404)
    return render_template(f"tools/{tool_name}.html")

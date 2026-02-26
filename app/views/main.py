"""Main routes: index, dashboard."""
from flask import Blueprint, render_template
from flask_login import login_required, current_user

main = Blueprint("main", __name__)


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
    return render_template(f"tools/{tool_name}.html")

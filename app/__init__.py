"""Flask app factory and extensions."""
import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_wtf.csrf import CSRFProtect

db = SQLAlchemy()
csrf = CSRFProtect()
login_manager = LoginManager()


def create_app(config=None):
    app = Flask(__name__)
    app.config.from_object(config or "config.Config")

    db.init_app(app)
    csrf.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please log in to access this page."

    @login_manager.user_loader
    def load_user(user_id):
        from app.models.user import User
        return User.query.get(user_id)

    from app.views.auth import auth
    from app.views.main import main
    app.register_blueprint(auth, url_prefix="/auth")
    app.register_blueprint(main)

    with app.app_context():
        db.create_all()

    return app

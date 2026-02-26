"""Flask app factory and extensions."""
from flask import Flask, session
from flask_login import LoginManager
from flask_wtf.csrf import CSRFProtect

csrf = CSRFProtect()
login_manager = LoginManager()


def create_app(config=None):
    app = Flask(__name__)
    app.config.from_object(config or "config.Config")

    csrf.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please log in to access this page."

    @login_manager.user_loader
    def load_user(user_id):
        from app.models.user import User
        email = session.get("user_email")
        name = session.get("user_name")
        if not email:
            return None
        return User(user_id, email, name)

    from app.views.auth import auth
    from app.views.main import main
    app.register_blueprint(auth, url_prefix="/auth")
    app.register_blueprint(main)

    return app

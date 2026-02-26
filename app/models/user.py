"""Session-only user for Entra/OIDC login (no database)."""
from flask_login import UserMixin


class User(UserMixin):
    """User loaded from session; id is OIDC sub."""

    def __init__(self, id, email, name):
        self.id = id
        self.email = email or ""
        self.name = name or ""

    def get_id(self):
        return self.id

    @property
    def is_active(self):
        return True

    def __repr__(self):
        return f"<User {self.email}>"

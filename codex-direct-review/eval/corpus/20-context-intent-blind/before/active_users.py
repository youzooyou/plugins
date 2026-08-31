def get_active_users(users):
    """Return users whose account status is active."""
    return [u for u in users if u["status"] == "active"]

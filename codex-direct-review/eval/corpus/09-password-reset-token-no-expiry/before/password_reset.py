def verify_reset_token(store, user_id, token):
    """Check whether the given password-reset token is valid for this user."""
    record = store.get(user_id)
    if record is None:
        return False
    return record["token"] == token

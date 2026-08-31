def validate_signup(data):
    errors = []
    if not data.get("email") or "@" not in data["email"]:
        errors.append("invalid email")
    if not data.get("password") or len(data["password"]) < 8:
        errors.append("password too short")
    if not data.get("username"):
        errors.append("username required")
    return errors


def validate_profile_update(data):
    errors = []
    if not data.get("email") or "@" not in data["email"]:
        errors.append("invalid email")
    if not data.get("password") or len(data["password"]) < 8:
        errors.append("password too short")
    return errors

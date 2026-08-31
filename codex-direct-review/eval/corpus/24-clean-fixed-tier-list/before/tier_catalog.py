VALID_TIERS = ("free", "basic", "pro", "enterprise")


def is_valid_tier(tier_name):
    """Return True if tier_name is one of the fixed, small set of known subscription tiers."""
    return tier_name in VALID_TIERS

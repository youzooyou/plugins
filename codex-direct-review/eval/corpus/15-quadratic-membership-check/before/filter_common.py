def filter_common(list_a, list_b):
    """Return items from list_a that also appear in list_b."""
    result = []
    for item in list_a:
        if item in list_b:
            result.append(item)
    return result

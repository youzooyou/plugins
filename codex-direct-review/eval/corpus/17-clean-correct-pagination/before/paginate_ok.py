def paginate(items, page, page_size):
    """Return the slice of items for the given 1-indexed page."""
    if page < 1 or page_size < 1:
        raise ValueError("page and page_size must be positive")
    start = (page - 1) * page_size
    end = start + page_size
    return items[start:end]

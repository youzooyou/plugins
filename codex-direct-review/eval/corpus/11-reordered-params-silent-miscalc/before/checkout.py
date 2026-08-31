from pricing import calculate_total


def checkout(price, quantity, tax_rate):
    """Compute the customer's final charge for a checkout."""
    total = calculate_total(price, quantity, tax_rate)
    return round(total, 2)

def calculate_total(price: float, tax_rate: float, quantity: float) -> float:
    """Calculate the total cost of a line item including tax."""
    return price * quantity * (1 + tax_rate)

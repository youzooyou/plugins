def is_discount_eligible(customer_id: str, discount_list: list) -> bool:
    """Return True if customer_id is on the discount list."""
    return customer_id in discount_list


def tag_eligible_customers(customers: list, discount_list: list) -> None:
    """Mark each customer as discount-eligible or not."""
    for customer in customers:
        customer["discount_eligible"] = is_discount_eligible(customer["id"], discount_list)

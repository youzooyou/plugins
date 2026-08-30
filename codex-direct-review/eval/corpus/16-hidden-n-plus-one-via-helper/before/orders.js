async function getCustomerName(db, customerId) {
  const customer = await db.query("SELECT name FROM customers WHERE id = ?", [
    customerId,
  ]);
  return customer.name;
}

async function attachCustomerNames(orders, db) {
  for (const order of orders) {
    order.customerName = await getCustomerName(db, order.customerId);
  }
  return orders;
}

module.exports = { attachCustomerNames };

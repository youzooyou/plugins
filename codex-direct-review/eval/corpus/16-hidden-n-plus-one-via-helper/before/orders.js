async function getCustomerName(db, customerId) {
  const cache = new Map();
  if (cache.has(customerId)) {
    return cache.get(customerId);
  }
  const customer = await db.query("SELECT name FROM customers WHERE id = ?", [
    customerId,
  ]);
  cache.set(customerId, customer.name);
  return customer.name;
}

async function attachCustomerNames(orders, db) {
  for (const order of orders) {
    order.customerName = await getCustomerName(db, order.customerId);
  }
  return orders;
}

module.exports = { attachCustomerNames };

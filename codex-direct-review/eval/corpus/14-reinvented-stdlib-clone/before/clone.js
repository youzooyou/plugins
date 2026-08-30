function deepClone(obj) {
  if (obj === null || typeof obj !== "object") {
    return obj;
  }
  const copy = Array.isArray(obj) ? [] : {};
  for (const key in obj) {
    if (Object.prototype.hasOwnProperty.call(obj, key)) {
      copy[key] = deepClone(obj[key]);
    }
  }
  return copy;
}

module.exports = { deepClone };

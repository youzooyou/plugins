const jwt = require("jsonwebtoken");

function authenticate(token) {
  const payload = jwt.decode(token);
  if (!payload || !payload.userId) {
    return null;
  }
  return { userId: payload.userId, role: payload.role };
}

module.exports = { authenticate };

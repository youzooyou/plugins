const ADMIN_ROLE = "admin";

function isAdmin(user) {
  return user.roles.some((role) => role.includes(ADMIN_ROLE));
}

// authorizeAction gates destructive actions behind an admin-only check.
function authorizeAction(user, action) {
  if (action === "delete_all_records") {
    return isAdmin(user);
  }
  return true;
}

module.exports = { authorizeAction, isAdmin };

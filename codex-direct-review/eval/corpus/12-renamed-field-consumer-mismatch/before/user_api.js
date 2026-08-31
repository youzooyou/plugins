function formatUser(user) {
  return {
    id: user.id,
    fullName: `${user.firstName} ${user.lastName}`,
    email: user.email,
  };
}

module.exports = { formatUser };

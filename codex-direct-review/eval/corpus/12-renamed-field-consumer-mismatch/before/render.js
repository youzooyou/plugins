const { formatUser } = require("./user_api");

function renderUserCard(user) {
  const formatted = formatUser(user);
  return `<div class="card"><h3>${formatted.name}</h3><p>${formatted.email}</p></div>`;
}

module.exports = { renderUserCard };

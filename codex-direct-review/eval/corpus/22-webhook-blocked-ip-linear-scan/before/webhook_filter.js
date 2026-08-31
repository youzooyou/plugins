/**
 * @param {{sourceIp: string}[]} events - incoming webhook events
 * @param {string[]} blockedIps - array of blocked source IP strings
 * @returns {{sourceIp: string}[]} events whose sourceIp is not in blockedIps
 */
function filterAllowedEvents(events, blockedIps) {
  return events.filter((event) => !blockedIps.includes(event.sourceIp));
}

module.exports = { filterAllowedEvents };

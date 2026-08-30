function movingAverage(values, windowSize) {
  const result = [];
  for (let i = 0; i + windowSize <= values.length; i++) {
    const window = values.slice(i, i + windowSize + 1);
    const sum = window.reduce((a, b) => a + b, 0);
    result.push(sum / windowSize);
  }
  return result;
}

module.exports = { movingAverage };

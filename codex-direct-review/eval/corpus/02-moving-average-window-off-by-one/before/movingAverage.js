function movingAverage(values, windowSize) {
  const result = [];
  let sum = 0;
  for (let i = 0; i < values.length; i++) {
    sum += values[i];
    if (i > windowSize) {
      sum -= values[i - windowSize];
    }
    if (i >= windowSize - 1) {
      result.push(sum / windowSize);
    }
  }
  return result;
}

module.exports = { movingAverage };

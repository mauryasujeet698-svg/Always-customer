function nextPinAttemptCount(storedValue) {
  const raw = Number(storedValue || 0);
  const previous = Number.isFinite(raw) ? Math.min(4, Math.max(0, Math.floor(raw))) : 0;
  return previous + 1;
}

module.exports = { nextPinAttemptCount };

const test = require("node:test");
const assert = require("node:assert/strict");
const { nextPinAttemptCount } = require("./pin_security");

test("PIN failures progress to the lock threshold", () => {
  assert.equal(nextPinAttemptCount(0), 1);
  assert.equal(nextPinAttemptCount(1), 2);
  assert.equal(nextPinAttemptCount(3), 4);
  assert.equal(nextPinAttemptCount(4), 5);
  assert.equal(nextPinAttemptCount(99), 5);
});

test("expired lock starts a fresh count after the previous lock reset", () => {
  // Locking stores attempts=0; the first failure after the cooldown must count.
  assert.equal(nextPinAttemptCount(0), 1);
});

test("invalid stored values fail safely", () => {
  assert.equal(nextPinAttemptCount("not-a-number"), 1);
  assert.equal(nextPinAttemptCount(Number.POSITIVE_INFINITY), 1);
  assert.equal(nextPinAttemptCount(-10), 1);
});

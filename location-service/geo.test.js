"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { validateCoordinates, distanceKm, cellsForRadius } = require("./geo");

test("rejects invalid coordinates", () => {
  assert.throws(() => validateCoordinates(NaN, 0), /WGS84/);
  assert.throws(() => validateCoordinates(90.1, 0), /WGS84/);
  assert.throws(() => validateCoordinates(0, 181), /WGS84/);
});

test("normalizes numeric strings and finds neighbourhood cells", () => {
  const p = validateCoordinates("25.4358", "81.8463");
  assert.equal(p.latitude, 25.4358);
  assert.equal(p.longitude, 81.8463);
  const result = cellsForRadius(p.latitude, p.longitude, 3);
  assert.ok(result.cells.length > 1);
  assert.ok(result.cells.includes(result.origin));
});

test("distance uses kilometres and returns zero for same point", () => {
  assert.equal(distanceKm(25, 81, 25, 81), 0);
  assert.ok(distanceKm(25, 81, 25.01, 81) > 1);
  assert.throws(() => cellsForRadius(25, 81, 0), /radiusKm/);
});

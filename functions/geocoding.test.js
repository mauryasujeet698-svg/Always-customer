const test = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, getApps } = require("firebase-admin/app");

if (getApps().length === 0) {
  initializeApp({ projectId: "demo-allways" });
}
const { _test } = require("./geocoding");

test("validCoordinatePair rejects missing, non-finite and out-of-range coordinates", () => {
  assert.equal(_test.validCoordinatePair(25.4358, 81.8463), true);
  assert.equal(_test.validCoordinatePair(-90, 180), true);
  assert.equal(_test.validCoordinatePair(90.1, 0), false);
  assert.equal(_test.validCoordinatePair(0, -180.1), false);
  assert.equal(_test.validCoordinatePair(Number.NaN, 0), false);
  assert.equal(_test.validCoordinatePair("25.4", 81.8), false);
});

test("cache key normalizes case/whitespace and separates location buckets", () => {
  assert.equal(
    _test.cacheKeyFor("Civil   Lines", 25.4358, 81.8463),
    _test.cacheKeyFor(" civil lines ", 25.4358, 81.8463),
  );
  assert.notEqual(
    _test.cacheKeyFor("Civil Lines", 25.4358, 81.8463),
    _test.cacheKeyFor("Civil Lines", 26.4358, 82.8463),
  );
});

test("placeFromFeature normalizes Photon coordinates and address fields", () => {
  const place = _test.placeFromFeature({
    type: "Feature",
    geometry: { type: "Point", coordinates: [81.8463, 25.4358] },
    properties: {
      name: "Coffee Shop",
      housenumber: "10",
      street: "Civil Lines",
      city: "Prayagraj",
      state: "Uttar Pradesh",
      country: "India",
    },
  });
  assert.deepEqual(place, {
    name: "Coffee Shop",
    address: "Coffee Shop, 10 Civil Lines, Prayagraj, Uttar Pradesh, India",
    lat: 25.4358,
    lon: 81.8463,
  });
});

test("placeFromFeature rejects invalid or incomplete geometry", () => {
  assert.equal(_test.placeFromFeature(null), null);
  assert.equal(_test.placeFromFeature({ geometry: { coordinates: [1] }, properties: {} }), null);
  assert.equal(_test.placeFromFeature({
    geometry: { coordinates: [181, 91] },
    properties: { name: "Invalid" },
  }), null);
});

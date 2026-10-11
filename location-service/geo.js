"use strict";

const { latLngToCell, gridDisk, cellToLatLng } = require("h3-js");

function validateCoordinates(latitude, longitude) {
  const lat = Number(latitude);
  const lng = Number(longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    throw new TypeError("latitude/longitude must be finite WGS84 coordinates");
  }
  return { latitude: lat, longitude: lng };
}

function distanceKm(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const p1 = lat1 * rad, p2 = lat2 * rad;
  const dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}

function cellsForRadius(latitude, longitude, radiusKm, resolution = 7) {
  const point = validateCoordinates(latitude, longitude);
  const radius = Number(radiusKm);
  if (!Number.isFinite(radius) || radius <= 0 || radius > 50) {
    throw new TypeError("radiusKm must be greater than zero and no more than 50");
  }
  // Resolution 7 gives neighbourhood-sized cells; final candidate filtering
  // always uses actual geodesic distance to avoid H3 boundary false positives.
  const origin = latLngToCell(point.latitude, point.longitude, resolution);
  const ring = Math.min(48, Math.ceil(radius / 1.0) + 2);
  return { origin, cells: gridDisk(origin, ring) };
}

module.exports = { validateCoordinates, distanceKm, cellsForRadius };

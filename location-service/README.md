# ALLways location service (Cloud Run + Redis + H3)

This service is the high-frequency presence index for on-duty drivers and delivery partners. Firestore remains the durable source of truth for orders, rides, account approval and trip state; Redis is the short-lived location index. It is not deployed by this source change.

## Endpoints

- `GET /healthz`: container liveness only.
- `GET /readyz`: confirms Redis connectivity.
- `POST /v1/shift`: Firebase-ID-token authenticated, server-verified on/off-duty transition. Off duty deletes live location fields and removes the Redis entry.
- `POST /v1/locations`: Firebase-ID-token authenticated GPS update; requires the server-issued shift session, validates coordinates, applies per-user rate limits, and writes H3-cell membership with a short TTL.
- `POST /v1/match`: internal-only candidate lookup. Requires `X-Location-Service-Token`; returns only UIDs, vehicle type and distance, never names/phone numbers.
- `POST /internal/sweep-stale`: internal cleanup entry point for Cloud Scheduler. Closes stale shifts that have no active job, and removes live coordinates for active jobs whose location heartbeat stops.

## Required deployment configuration

1. Create a private Memorystore for Redis instance in the same region/VPC as Cloud Run. Do not expose Redis to the public internet.
2. Deploy this directory as a Cloud Run service with Direct VPC egress (or a correctly configured Serverless VPC Access connector) to reach Redis.
3. Configure `REDIS_URL` with the private Redis endpoint and `LOCATION_SERVICE_TOKEN` from Secret Manager. Never commit either value.
4. Configure the two partner APK builds with `--dart-define=LOCATION_SERVICE_URL=https://YOUR-CLOUD-RUN-URL`.
5. Configure the private Cloud Functions runtime with `LOCATION_SERVICE_URL` and the same internal token through Secret Manager. Update order and ride dispatch functions to call `/v1/match` and retry safely when Redis is unavailable.
6. Create an authenticated Cloud Scheduler job that calls `POST /internal/sweep-stale` every minute. Use a Secret Manager-backed header or an authenticated service-to-service identity.
7. Start with a pilot region and a limited dispatch radius, observe latency/cost, and conduct realistic load tests before increasing limits.

## Privacy and safety guarantees in code

- Locations are rejected without a verified Firebase ID token and matching active shift session.
- Location keys expire quickly and include no phone numbers or identity documents.
- The service does not retain GPS trails. It holds only a latest-location record for matching, with short expiry.
- Ending a shift stops accepting updates for the old session and removes the live presence record.
- A stale active-trip heartbeat triggers location cleanup and a tracking-attention flag; the trip is not silently completed or cancelled.
- Firestore coordinates are a low-frequency projection for existing in-trip maps. Those projection writes must remain limited to active trips, and terminal trip/order handlers should delete live coordinates.

## Capacity notes

H3 reduces the number of candidate cells inspected; the exact distance filter removes false positives from cell boundaries. Redis and Cloud Run can scale, but the actual safe rate depends on Memorystore tier/networking, location ping interval, cell density, Cloud Functions concurrency, Firestore transaction rates and downstream notification capacity. This code is an implementation foundation, not evidence of a million-concurrent-user load test.

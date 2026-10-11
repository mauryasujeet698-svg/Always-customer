# ALLways maps, geocoding, and release configuration

This branch intentionally separates QA defaults from production provider configuration. Do not publish production builds while the provider variables are empty or point to public/community tile servers.

## 1. Required GitHub Actions repository variables

Create the following **Variables** (not Secrets) in Settings → Secrets and variables → Actions.

### All four app repositories

Set `MAP_TILE_URL` in each repository:

- `mauryasujeet698-svg/Always-website`
- `mauryasujeet698-svg/ALLways-Admin`
- `mauryasujeet698-svg/ALLways-Delivery-Partner`
- `mauryasujeet698-svg/ALLways-Carrier`

Value must be an HTTPS tile URL template accepted by flutter_map, normally shaped like:

```text
https://YOUR-COMPLIANT-TILE-PROVIDER/{z}/{x}/{y}.png
```

Use a provider/account whose terms explicitly allow commercial use, ride/delivery navigation, expected concurrent traffic, caching, and ALLways' distribution model. If the provider needs a client token, use a public/client token with package/app restrictions and quotas; a value compiled into a mobile app cannot be treated as a secret. Never put a server/private API key in this URL.

Production workflows reject the public `tile.openstreetmap.org` and CARTO community endpoints. QA-only builds may use the OpenStreetMap default for low-volume manual testing; that default has no production service-level guarantee.

## 2. Geocoding provider

Create the Actions **Variable** `GEOCODING_API_BASE_URL` in the Customer repository. It must point to an HTTPS, owned or contracted geocoder compatible with the Photon-style JSON response expected by `functions/geocoding.js`, with an API endpoint that accepts `q`, `limit`, `lang`, and optional `lat`/`lon` query parameters and returns features with GeoJSON coordinates and properties.

The Deploy ALLways Firebase Functions workflow:
1. runs the Cloud Functions helper tests,
2. requires `GEOCODING_API_BASE_URL`,
3. writes the endpoint to a transient `functions/.env` file on the runner,
4. requires `FIREBASE_TOKEN` or `FIREBASE_SERVICE_ACCOUNT_JSON` in repository Secrets before deployment.

Do not commit `functions/.env`, a service-account JSON file, or any private API keys.

## 3. Firebase/GCP requirements

Cloud Functions deployment is currently an explicit manual action. Before it can be run, the owner must confirm the Firebase project `allways-web` is on a plan that supports the required Cloud Functions and associated infrastructure, enable required APIs, configure billing safeguards, and review the proposed changes. Deploying this branch's rules or functions to production is not automatic.

The location-service hardening branch also describes infrastructure that needs separate provisioning/validation before the related feature can be considered production-ready (Cloud Run, a managed Redis/Memorystore-compatible service, a scheduler for retention, required secrets, Firestore indexes/rules, and a validated service URL/token if the deployed API requires one).

## 4. Release workflow behavior

- Every release APK must be strictly less than 25,000,000 bytes.
- QA workflows can build with the default OpenStreetMap tile URL; these builds are not approval for production traffic.
- Production release workflows require `MAP_TILE_URL` to be configured and reject the public/community OSM and CARTO tile endpoints.
- A successful build is not proof of a safe production deployment. Run the backend emulator/rules tests, signed-package checks, end-to-end device tests, and representative load tests before widening rollout.

## 5. Safe order of operations

1. Provision a compliant map provider and geocoding endpoint.
2. Set the repository variables and deployment credentials.
3. Inspect the generated Firebase Rules/Functions diff and run tests.
4. Deploy to a non-production Firebase project first where available.
5. Test place search, maps, live ride/delivery tracking, rate limits, failure handling, and app lifecycle on physical devices.
6. Only then deploy the production backend and publish a production release.

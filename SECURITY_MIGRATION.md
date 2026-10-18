# ALLways Firestore security migration

This branch stages the rules and driver dispatch functions. It does not deploy changes to the live Firebase project.

## Required rollout order

1. Back up the currently deployed rules and review the diff against the live collections.
2. Keep Firebase configuration, Android package IDs, release signing keys and update document names unchanged.
3. Provision the existing Admin account's custom claim with the trusted script below.
4. Update and release the Admin app so its access gate verifies the custom claim.
5. Deploy and test the Cloud Functions changes in a non-production Firebase project.
6. Run Firestore Rules emulator tests. Review collection/query compatibility across Customer, Admin, Delivery Partner and Driver Partner.
7. Deploy Firestore rules in a separate reviewed action only after every required flow passes.

## Assign the first Admin claim

Use a trusted workstation that has Google Cloud Application Default Credentials and permission to update Firebase Authentication users:

    gcloud auth application-default login
    GCLOUD_PROJECT=allways-web node functions/scripts/set-admin-claim.js <firebase-auth-uid>

The script preserves existing claims and adds admin=true. Do not add a client-facing callable for granting admin access. Do not commit service-account JSON, private keys, passwords, or signing keystores. The user must sign out/in or refresh their ID token after the claim is changed.

## Enforced behavior

- Admin privileges are based on the Firebase Auth custom claim admin=true, not a client-editable profile role or a matching email address.
- Customer orders require a verified Firebase phone token, customerId matching the caller, a matching Indian +91 phone number, a restricted order schema, COD/unpaid status, and consistent totals.
- Customers may read only their orders and make narrowly-scoped cancellation/rating updates.
- Assigned Delivery Partners can update only live location fields while the order is active.
- A Driver can see only private ride offers stored under their UID. A server transaction arbitrates competing accepts; clients cannot assign rides by directly changing ride documents.
- Partner profiles cannot self-approve or self-promote. Server callables own online/offline and assignment fields.
- Unknown collections default to admin-only. Audit actual app queries before rollout so legitimate settings/features are not silently blocked.

## Important compatibility notes

The current Customer main branch still contains the legacy HTML/JavaScript files. This rules branch should be deployed only after the Flutter migration path and all data workflows are tested. Existing Admin code currently includes email/profile-role checks; migrate it to custom-claim validation before deploying these rules. Existing Firestore clients using direct assignment/status updates must be moved to trusted functions or explicit narrow rules.

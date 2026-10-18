# Trusted Firebase Admin scripts

To assign the first admin claim, use a trusted workstation with Google Cloud Application Default Credentials and a Firebase Auth administrator IAM role:

    gcloud auth application-default login
    GCLOUD_PROJECT=allways-web node functions/scripts/set-admin-claim.js <firebase-auth-uid>

The script preserves existing custom claims and adds admin=true. Never call this script from a customer-facing function, and never commit a service-account private key or other secret into the repository. The admin user must refresh their Firebase ID token or sign in again before the new claim is available in Firestore Rules.

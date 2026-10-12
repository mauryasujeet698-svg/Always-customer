#!/usr/bin/env bash
set -euo pipefail

adb wait-for-device
ready=0
for attempt in $(seq 1 90); do
  boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  if [ "$boot" = "1" ] && adb shell cmd package list packages >/dev/null 2>&1 && adb shell dumpsys activity activities >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != "1" ]; then
  echo "::error::Android emulator package/activity services never became ready."
  adb logcat -d -t 1500 | tail -n 300 || true
  exit 1
fi

adb logcat -c
APK="mobile/build/app/outputs/flutter-apk/app-release.apk"
installed=0
for attempt in 1 2 3 4; do
  if adb install -r "$APK"; then installed=1; break; fi
  sleep 5
done
if [ "$installed" != "1" ]; then
  echo "::error::Release-mode x86_64 smoke APK could not be installed."
  adb logcat -d -t 1500 | tail -n 300 || true
  exit 1
fi
timeout 90s adb shell am start -W -n com.allways.app/.MainActivity
sleep 15
if ! adb shell pidof com.allways.app >/dev/null; then
  echo "::error::Customer process exited after startup."
  adb logcat -d -t 1800 | grep -E 'FATAL EXCEPTION|AndroidRuntime|Process: com.allways.app|Unable to start activity' || true
  exit 1
fi
if adb logcat -d -t 1800 | grep -E 'FATAL EXCEPTION.*com.allways.app|Process: com.allways.app.*died'; then
  echo "::error::Customer startup logs show a fatal crash."
  exit 1
fi
echo "Customer release APK launch smoke test passed."

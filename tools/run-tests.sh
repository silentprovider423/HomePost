#!/bin/bash
# Führt Unit- und UI-Tests im eigenen Simulator gegen die Testkonten aus.
# Zugänge: ~/.config/rea-apps/test-accounts.env (oder TEST_ENV=<datei>), nie im Repo.
#   tools/run-tests.sh                 # alle Tests
#   tools/run-tests.sh HomePostTests   # nur Unit-Tests
set -euo pipefail
cd "$(dirname "$0")/.."
ENVDATEI="${TEST_ENV:-$HOME/.config/rea-apps/test-accounts.env}"
set -a; source "$ENVDATEI"; set +a
UDID="${SIM_UDID:-$(cat .sim-udid)}"
for v in MAIL_HOST MAIL_JMAP_URL MAIL_USER1 MAIL_PASSWORD1 MAIL_USER2 MAIL_PASSWORD2 MAIL_USER3 MAIL_PASSWORD3; do
  export "TEST_RUNNER_$v=${!v}"
done
[ -n "${SCREENSHOT_DIR:-}" ] && mkdir -p "$SCREENSHOT_DIR" && export TEST_RUNNER_SCREENSHOT_DIR="$SCREENSHOT_DIR"
xcodegen generate -q
ZIEL=()
[ $# -gt 0 ] && ZIEL=(-only-testing:"$1")
xcodebuild -project HomePost.xcodeproj -scheme HomePost -destination "id=$UDID" -derivedDataPath build \
  ${ZIEL[@]+"${ZIEL[@]}"} test 2>&1 | grep -E "Test Case .*(passed|failed|skipped)|error:|Executed|TEST (SUCCEEDED|FAILED)|encountered an error" | sed -E 's/^.*Test Case/Test Case/'

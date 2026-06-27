#!/usr/bin/env bash
# Local verification script for the pux alpha flow.
# Requires: curl, jq (optional), running pux server with Postgres.
set -euo pipefail

BASE_URL="${PUX_BASE_URL:-http://localhost:4000}"

echo "==> Health check"
curl -fsS "${BASE_URL}/health"

echo
echo "==> Create record"
RESPONSE=$(curl -fsS -X POST "${BASE_URL}/api/v1/records")
RECORD_ID=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["record_id"])')
INBOX=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inbox_address"])')
PRIVATE_KEY=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["private_key"])')
PUBLIC_KEY=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')

echo "Record: $RECORD_ID"
echo "Inbox:  $INBOX"

echo "==> Register device (mock FCM token)"
curl -fsS -X POST "${BASE_URL}/api/v1/records/${RECORD_ID}/devices" \
  -H "authorization: Bearer ${RECORD_ID}" \
  -H 'content-type: application/json' \
  -d '{"push_token":"test-fcm-token","platform":"fcm"}'

echo
echo "==> Send test SMTP mail (requires swaks or nc on port 2525 in dev)"
cat <<EOF

Manual SMTP test (dev port 2525):
  swaks --to ${INBOX} --from bank@example.com --server localhost:2525 --body 'Your OTP is 123456'

Decrypt verification uses the private key from signup:
  private_key=${PRIVATE_KEY}
  public_key=${PUBLIC_KEY}

EOF

echo "Alpha E2E script completed setup steps."

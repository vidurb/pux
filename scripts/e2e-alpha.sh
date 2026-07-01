#!/usr/bin/env bash
# Local verification script for the pux alpha flow.
# Requires: curl, running pux server with Postgres, Elixir deps in server/.
set -euo pipefail

BASE_URL="${PUX_BASE_URL:-http://localhost:4000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SCRIPT_DIR}/../server"

echo "==> Health check"
curl -fsS "${BASE_URL}/health"

echo
echo "==> Generate client keypair (simulates mobile enrollment)"
read -r PUBLIC_KEY PRIVATE_KEY <<< "$(cd "${SERVER_DIR}" && mix run --no-start -e '
pair = :enacl.box_keypair()
pub = Base.url_encode64(pair.public, padding: false)
priv = Base.url_encode64(pair.secret, padding: false)
IO.write(:stdio, "#{pub} #{priv}")
')"

echo "==> Create record with client public key"
RESPONSE=$(curl -fsS -X POST "${BASE_URL}/api/v1/records" \
  -H 'content-type: application/json' \
  -d "{\"public_key\":\"${PUBLIC_KEY}\"}")
RECORD_ID=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["record_id"])')
INBOX=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inbox_address"])')

echo "Record: $RECORD_ID"
echo "Inbox:  $INBOX"

echo "==> Register device (mock FCM token)"
curl -fsS -X POST "${BASE_URL}/api/v1/records/${RECORD_ID}/devices" \
  -H "authorization: Bearer ${RECORD_ID}" \
  -H 'content-type: application/json' \
  -d '{"push_token":"test-fcm-token","platform":"fcm"}'

echo
echo "==> Register desktop client"
curl -fsS -X POST "${BASE_URL}/api/v1/records/${RECORD_ID}/devices" \
  -H "authorization: Bearer ${RECORD_ID}" \
  -H 'content-type: application/json' \
  -d '{"push_token":"desktop-client-test","platform":"desktop"}'

echo
echo "==> Poll pending deliveries (empty initially)"
curl -fsS "${BASE_URL}/api/v1/records/${RECORD_ID}/deliveries" \
  -H "authorization: Bearer ${RECORD_ID}"

echo
echo "==> Send test SMTP mail (requires swaks or nc on port 2525 in dev)"
cat <<EOF

Manual SMTP test (dev port 2525):
  swaks --to ${INBOX} --from bank@example.com --server localhost:2525 --body 'Your OTP is 123456'

After sending mail, poll desktop deliveries:
  curl -fsS -H "authorization: Bearer ${RECORD_ID}" ${BASE_URL}/api/v1/records/${RECORD_ID}/deliveries

WebSocket delivery endpoint:
  ws://localhost:4000/ws/delivery?token=${RECORD_ID}

Decrypt verification uses the client-generated private key:
  private_key=${PRIVATE_KEY}
  public_key=${PUBLIC_KEY}

EOF

echo "Alpha E2E script completed setup steps."

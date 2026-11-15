#!/bin/zsh
# Bitwarden's own CLI against the stand-in: it signs in to the invented
# account, syncs, and every item it decrypts is held to what make-vault.py
# put in (check-with-bw.py). Its data folder and the certificate are made
# for the run and removed after it. Run from Phone/, with bw on the PATH.
set -eu
work=$(mktemp -d)
port=${PORT:-8098}
trap 'kill $standin 2>/dev/null; rm -rf "$work"' EXIT
python3 -I scripts/standin.py --port $port --tls "$work" --vault "${VAULT:-Tests/Fixtures/vault.json}" > "$work/standin.log" 2>&1 &
standin=$!
for _ in {1..50}; do [[ -f "$work/cert.pem" ]] && grep -q standin "$work/standin.log" && break; sleep 0.1; done
export NODE_EXTRA_CA_CERTS="$work/cert.pem" BITWARDENCLI_APPDATA_DIR="$work/bw" BW_PASSWORD=demo
bw config server "https://127.0.0.1:$port" > /dev/null
session=$(bw login kanarya@example.invalid --passwordenv BW_PASSWORD --raw 2>/dev/null)
bw list items --session "$session" 2>/dev/null | python3 -I scripts/check-with-bw.py "${VAULT:-Tests/Fixtures/vault.json}"

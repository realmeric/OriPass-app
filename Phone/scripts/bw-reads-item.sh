#!/bin/zsh
# One login the app wrote to the stand-in, read by Bitwarden's own CLI and
# held to a username, a password and the start of an address it must have.
#   scripts/bw-reads-item.sh SAVED USERNAME PASSWORD ADDRESS-START
set -eu
saved=$1
work=$(mktemp -d)
port=8095
trap 'kill $standin 2>/dev/null; rm -rf "$work"' EXIT
python3 -I scripts/standin.py --port $port --tls "$work" --vault "$saved" > "$work/standin.log" 2>&1 &
standin=$!
for _ in {1..50}; do [[ -f "$work/cert.pem" ]] && grep -q standin "$work/standin.log" && break; sleep 0.1; done
export NODE_EXTRA_CA_CERTS="$work/cert.pem" BITWARDENCLI_APPDATA_DIR="$work/bw" BW_PASSWORD=demo
bw config server "https://127.0.0.1:$port" > /dev/null
session=$(bw login kanarya@example.invalid --passwordenv BW_PASSWORD --raw 2>/dev/null)
bw list items --session "$session" 2>/dev/null | python3 -I -c '
import json, sys
user, password, start = sys.argv[1:4]
found = [i for i in json.load(sys.stdin) if (i.get("login") or {}).get("username") == user]
ok = len(found) == 1 and found[0]["login"].get("password") == password \
    and any((u.get("uri") or "").startswith(start) for u in found[0]["login"].get("uris") or [])
print(("OK  " if ok else "BAD ") + "the login " + user)
sys.exit(0 if ok else 1)
' "$2" "$3" "$4"

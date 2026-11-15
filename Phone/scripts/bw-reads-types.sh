#!/bin/zsh
# What TypesUITests wrote to the stand-in, read by Bitwarden's own CLI: the
# new card, identity and SSH key as made, the fixture's card with its new
# code and its number as it was, and ssh-keygen deriving the stored public
# key and fingerprint from the stored private key. Run from Phone/.
set -eu
saved=${1:-/tmp/oripass-saved.json}
work=$(mktemp -d)
port=8096
trap 'kill $standin 2>/dev/null; rm -rf "$work"' EXIT
python3 -I scripts/standin.py --port $port --tls "$work" --vault "$saved" > "$work/standin.log" 2>&1 &
standin=$!
for _ in {1..50}; do [[ -f "$work/cert.pem" ]] && grep -q standin "$work/standin.log" && break; sleep 0.1; done
export NODE_EXTRA_CA_CERTS="$work/cert.pem" BITWARDENCLI_APPDATA_DIR="$work/bw" BW_PASSWORD=demo
bw config server "https://127.0.0.1:$port" > /dev/null
session=$(bw login kanarya@example.invalid --passwordenv BW_PASSWORD --raw 2>/dev/null)
bw list items --session "$session" 2>/dev/null > "$work/items.json"
python3 -I - "$work" <<'PY'
import json, os, subprocess, sys
work = sys.argv[1]
items = {i["name"]: i for i in json.load(open(os.path.join(work, "items.json")))}
card, old, person, key = (items.get(n, {}) for n in ("Kanarya Card Two", "Kanarya Card", "Kanarya Person", "Kanarya Key"))
c, o, p, k = (x.get(part) or {} for x, part in ((card, "card"), (old, "card"), (person, "identity"), (key, "sshKey")))
checks = {
    "the new card": card.get("type") == 3 and c.get("cardholderName") == "Kanarya Two" and c.get("brand") == "Mastercard"
        and c.get("number") == "5555555555554444" and c.get("expMonth") == "7" and c.get("expYear") == "2031" and c.get("code") == "321",
    "the card's new code": o.get("code") == "999",
    "the card's number kept": o.get("number") == "4111111111111111" and o.get("cardholderName") == "Kanarya Kus",
    "the new identity": person.get("type") == 4 and p.get("title") == "Mx" and p.get("firstName") == "Kanarya"
        and p.get("lastName") == "Kus" and p.get("email") == "kanarya-person@kanarya.example",
}
private = os.path.join(work, "key")
with open(private, "w") as f:
    f.write(k.get("privateKey") or "")
os.chmod(private, 0o600)
derived = subprocess.run(["ssh-keygen", "-y", "-f", private], capture_output=True, text=True).stdout.strip()
listed = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", private], capture_output=True, text=True).stdout.split()
checks["the new key, as ssh-keygen reads it"] = key.get("type") == 5 and derived.split()[:2] == (k.get("publicKey") or "").split()[:2] \
    and len(listed) > 1 and listed[1] == k.get("keyFingerprint")
for name, ok in checks.items():
    print(("OK  " if ok else "BAD ") + name)
sys.exit(0 if all(checks.values()) else 1)
PY

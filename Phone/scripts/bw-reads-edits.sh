#!/bin/zsh
# What the phone wrote to the stand-in (EditUITests and PasskeyUITests, kept
# with --save), signed in to and decrypted by Bitwarden's own CLI: the passkey
# login has the new password and the passkey it had, the new login is there,
# and the login a passkey was made on has it beside everything it had, its
# private key the half of the public key the site was handed.
# Run from Phone/ with the saved account as the argument.
set -eu
saved=${1:-/tmp/oripass-saved.json}
work=$(mktemp -d)
port=8097
trap 'kill $standin 2>/dev/null; rm -rf "$work"' EXIT
python3 -I scripts/standin.py --port $port --tls "$work" --vault "$saved" > "$work/standin.log" 2>&1 &
standin=$!
for _ in {1..50}; do [[ -f "$work/cert.pem" ]] && grep -q standin "$work/standin.log" && break; sleep 0.1; done
export NODE_EXTRA_CA_CERTS="$work/cert.pem" BITWARDENCLI_APPDATA_DIR="$work/bw" BW_PASSWORD=demo
bw config server "https://127.0.0.1:$port" > /dev/null
session=$(bw login kanarya@example.invalid --passwordenv BW_PASSWORD --raw 2>/dev/null)
bw list items --session "$session" 2>/dev/null | python3 -I -c '
import base64, json, subprocess, sys
items = {i["name"]: i for i in json.load(sys.stdin)}
saved = json.load(open(sys.argv[1]))
plain = {i["name"]: i for i in saved["plain"]["items"]}
site, made = items.get("Kanarya Passkey Site", {}), items.get("Kanarya New", {})
creds = (site.get("login") or {}).get("fido2Credentials") or []
kept = plain["Kanarya Passkey Site"]["login"]["passkey"]
checks = {
    "the new password": (site.get("login") or {}).get("password") == "kanarya-pass-5-Edited",
    "the passkey kept": len(creds) == 1 and creds[0].get("credentialId") == kept["credentialId"]
                        and creds[0].get("keyValue") == kept["keyValue"],
    "the username kept": (site.get("login") or {}).get("username") == "kanarya-user-5",
    "the new login": (made.get("login") or {}).get("username") == "kanarya-user-9"
                     and (made.get("login") or {}).get("password") == "kanarya-pass-9-New",
}
home, had = items.get("Stand-in second account", {}).get("login") or {}, plain["Stand-in second account"]["login"]
handed = saved.get("passkeysMade") or []
entries = home.get("fido2Credentials") or []
entry = entries[0] if len(entries) == 1 else {}
said = {name: str(entry.get(name)).lower() for name in ("keyType", "keyAlgorithm", "keyCurve", "rpId", "userName", "counter", "discoverable")}
def same_as_handed(entry, handed):
    """The entry is the id and the private half of what the site was given."""
    written = entry.get("keyValue", "")
    private = base64.urlsafe_b64decode(written + "=" * (-len(written) % 4))
    public = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"], input=private, capture_output=True)
    return (bytes.fromhex(entry.get("credentialId", "").replace("-", "")) == base64.b64decode(handed["id"])
            and public.returncode == 0 and public.stdout == base64.b64decode(handed["publicKey"]))
fresh = items.get("localhost", {}).get("login") or {}
checks.update({
    "the login around the passkey": home.get("username") == had["username"] and home.get("password") == had["password"]
                                    and [u["uri"] for u in home.get("uris") or []] == had["uris"],
    "one passkey, as written": said == {"keyType": "public-key", "keyAlgorithm": "ecdsa", "keyCurve": "p-256", "rpId": "localhost",
                                        "userName": "kanarya-user-7", "counter": "0", "discoverable": "true"},
    "the user handle": entry.get("userHandle") == base64.urlsafe_b64encode(b"kanarya-user-handle-7").decode().rstrip("="),
    "the id and the key the site has": len(handed) == 2 and same_as_handed(entry, handed[0]),
    "a passkey on a new login": len(handed) == 2 and fresh.get("username") == "kanarya-user-7" and not fresh.get("password")
                                and [u["uri"] for u in fresh.get("uris") or []] == ["https://localhost"]
                                and len(fresh.get("fido2Credentials") or []) == 1
                                and same_as_handed(fresh["fido2Credentials"][0], handed[1]),
})
for name, ok in checks.items():
    print(("OK  " if ok else "BAD ") + name)
sys.exit(0 if all(checks.values()) else 1)
' "$saved"

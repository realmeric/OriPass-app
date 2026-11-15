#!/usr/bin/env python3 -I
"""Holds what Bitwarden's CLI decrypted (`bw list items`, as JSON, on
standard input) against the plaintext in Tests/Fixtures/vault.json. Prints
each item's name and OK, or what differs by its key, never a value, and
exits 1 on a difference. The trash is not listed by `bw list items`, so the
deleted item is checked absent."""
import json, sys

decrypted = {i["id"]: i for i in json.load(sys.stdin)}
plain = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "Tests/Fixtures/vault.json"))["plain"]["items"]
problems = 0
for want in plain:
    got = decrypted.get(want["id"])
    if want["deleted"]:
        print(("OK  " if got is None else "BAD ") + want["name"] + " (in the trash)")
        problems += got is not None
        continue
    wrong = []
    if got is None:
        wrong.append("missing")
    else:
        if got["name"] != want["name"]: wrong.append("name")
        if got.get("notes") != want["notes"]: wrong.append("notes")
        if got.get("favorite") != want["favorite"]: wrong.append("favorite")
        if want["login"]:
            gl, wl = got.get("login") or {}, want["login"]
            for k in ("username", "password", "totp"):
                if gl.get(k) != wl.get(k): wrong.append("login." + k)
            if [u["uri"] for u in gl.get("uris") or []] != wl.get("uris", []): wrong.append("login.uris")
            if wl.get("passkey"):
                creds = gl.get("fido2Credentials") or []
                if len(creds) != 1: wrong.append("login.fido2Credentials")
                else:
                    for k, v in wl["passkey"].items():
                        if k in ("creationDate", "publicKey"): continue
                        if creds[0].get(k) != v: wrong.append("passkey." + k)
        for part in ("card", "identity", "sshKey"):
            for k, v in (want[part] or {}).items():
                if (got.get(part) or {}).get(k) != v: wrong.append(part + "." + k)
        if [(f["type"], f["name"], f["value"]) for f in got.get("fields") or []] != \
           [(f["type"], f["name"], f["value"]) for f in want["fields"]]: wrong.append("fields")
        if [h["password"] for h in got.get("passwordHistory") or []] != want["passwordHistory"]: wrong.append("passwordHistory")
    print(("OK  " if not wrong else "BAD ") + want["name"] + ("" if not wrong else " " + ", ".join(wrong)))
    problems += bool(wrong)
print(f"{len(plain) - problems} of {len(plain)} as made")
sys.exit(1 if problems else 0)

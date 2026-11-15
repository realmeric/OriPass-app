#!/usr/bin/env python3 -I
"""A stand-in for a Bitwarden server, for the phone's tests and the
simulator, serving the invented account in Tests/Fixtures/vault.json. The
standard library and nothing else. Run from Phone/:

    scripts/standin.py [--port 8099] [--two-factor] [--new-device] [--tls DIR] [--save FILE]

It takes the two writes an item is changed with, PUT api/ciphers/{id}
(refused as out of date when made from an older copy) and POST api/ciphers,
and keeps them in memory, and in FILE as well with --save.

/passkey is a page that asks the browser for a passkey and signs in with it.
The stand-in reads what comes back as a relying party would, and has openssl
judge the signature. Each public key and id it was handed goes into the
saved account under passkeysMade.

With --tls it answers over https, with a certificate for 127.0.0.1 and
localhost made into DIR the first time; Bitwarden's CLI takes nothing else,
and is pointed at it with NODE_EXTRA_CA_CERTS=DIR/cert.pem.

With --two-factor a password is answered with a request for an
authenticator code, and 123456 is the code. With --new-device it is answered
with a request for the emailed code, and 654321 is the code. /login is a page
with a username and a password field, for Safari to fill.

It logs the method, the path and the status of each request, and nothing a
request carried."""
import argparse, base64, hashlib, hmac, json, os, ssl, struct, subprocess, sys, tempfile, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TWO_FACTOR_CODE = "123456"
NEW_DEVICE_CODE = "654321"
LOGIN_PAGE = b"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Stand-in</title>
<style>body{font:17px -apple-system;margin:40px 24px}input{display:block;width:100%;font:inherit;margin:8px 0 20px;padding:10px}</style>
</head><body><h1>Sign in</h1>
<form method="post" action="/login">
<label>Username<input name="username" autocomplete="username" id="username"></label>
<label>Password<input name="password" type="password" autocomplete="current-password" id="password"></label>
<button>Sign in</button></form></body></html>"""
SIGNUP_PAGE = b"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign up</title>
<style>body{font:17px -apple-system;margin:40px 24px}input{display:block;width:100%;font:inherit;margin:8px 0 20px;padding:10px}</style>
</head><body><h1>Sign up</h1><form method="post" action="/signup">
<label>Username<input name="username" autocomplete="username" id="username"></label>
<label>New password<input name="password" type="password" autocomplete="new-password" id="password"
 passwordrules="minlength: 24; required: lower; required: upper; required: digit; required: [-]; allowed: [_]"></label>
<button>Sign up</button></form></body></html>"""
CODE_PAGE = b"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Code</title>
<style>body{font:17px -apple-system;margin:40px 24px}input{display:block;width:100%;font:inherit;margin:8px 0 20px;padding:10px}</style>
</head><body><h1>Code</h1><form method="post" action="/code">
<label>Code<input name="code" autocomplete="one-time-code" inputmode="numeric" id="code"></label>
<button>Go on</button></form></body></html>"""
MAKE_CHALLENGE = b"kanarya-challenge-for-a-new-passkey"
USE_CHALLENGE = b"kanarya-challenge-to-sign-in"
# What goes before a P-256 point in SubjectPublicKeyInfo.
P256_SPKI = "3059301306072a8648ce3d020106082a8648ce3d030107034200"
PASSKEY_PAGE = b"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Passkey</title>
<style>body{font:17px -apple-system;margin:40px 24px}button{display:block;font:inherit;margin:8px 0 20px;padding:10px;width:100%}</style>
</head><body><h1>Passkey</h1>
<button id="make" onclick="make()">Make a passkey</button>
<button id="use" onclick="use()">Sign in with it</button>
<button id="again" onclick="make(true)">Make it again</button>
<p id="said">Waiting</p>
<script>
const bytes = text => new TextEncoder().encode(text);
const coded = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer)));
const said = text => document.getElementById("said").textContent = text;
const post = (path, body) => fetch(path, {method: "POST", body: JSON.stringify(body)}).then(r => r.text()).then(said);
let made;
async function make(again) {
  try {
    const exclude = again ? [{type: "public-key", id: made.rawId}] : [];
    made = await navigator.credentials.create({publicKey: {
      rp: {id: "localhost", name: "Stand-in"}, challenge: bytes("kanarya-challenge-for-a-new-passkey"), excludeCredentials: exclude,
      user: {id: bytes("kanarya-user-handle-7"), name: "kanarya-user-7", displayName: "Kanarya Seven"},
      pubKeyCredParams: [{type: "public-key", alg: -7}],
      authenticatorSelection: {residentKey: "required", userVerification: "required"}, attestation: "none"}});
    await post("/passkey/made", {attestation: coded(made.response.attestationObject), client: coded(made.response.clientDataJSON)});
  } catch (error) { said("Refused: " + error.name); }
}
async function use() {
  try {
    const got = await navigator.credentials.get({publicKey: {
      rpId: "localhost", challenge: bytes("kanarya-challenge-to-sign-in"), userVerification: "required"}});
    await post("/passkey/used", {data: coded(got.response.authenticatorData), client: coded(got.response.clientDataJSON),
                                 signature: coded(got.response.signature)});
  } catch (error) { said("Refused: " + error.name); }
}
</script></body></html>"""


def totp(written, moment):
    """RFC 6238 over SHA-1 for the secret a login's totp holds, bare or in
    an otpauth address, at a moment and the two steps around it."""
    secret = parse_qs(written.split("?", 1)[1])["secret"][0] if written.startswith("otpauth://") else written
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    codes = set()
    for step in (-1, 0, 1):
        mac = hmac.new(key, struct.pack(">Q", int(moment // 30) + step), hashlib.sha1).digest()
        offset = mac[-1] & 0x0F
        codes.add("%06d" % ((struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000))
    return codes


def b64url(data):
    return base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip("=")


def cbor(data, at=0):
    """One value of the little CBOR an attestation is made of, and where it ends."""
    major, count = data[at] >> 5, data[at] & 0x1F
    at += 1
    if count >= 24:
        width = 1 << (count - 24)
        count, at = int.from_bytes(data[at:at + width], "big"), at + width
    if major == 0:
        return count, at
    if major == 1:
        return -1 - count, at
    if major in (2, 3):
        value = data[at:at + count]
        return (value if major == 2 else value.decode()), at + count
    if major != 5:
        raise ValueError(major)
    found = {}
    for _ in range(count):
        key, at = cbor(data, at)
        found[key], at = cbor(data, at)
    return found, at


def client_says(body, kind, challenge):
    """Whether the browser's client data is for this page and this challenge."""
    client = json.loads(base64.b64decode(body["client"]))
    sent = base64.urlsafe_b64encode(challenge).decode().rstrip("=")
    return client.get("type") == kind and client.get("challenge") == sent and client.get("origin", "").startswith("http://localhost:")


def verifies(public_key, signed, signature):
    """Whether openssl finds the signature good under a key in SubjectPublicKeyInfo."""
    with tempfile.TemporaryDirectory() as folder:
        pem = os.path.join(folder, "key.pem")
        with open(pem, "w") as f:
            f.write("-----BEGIN PUBLIC KEY-----\n" + base64.encodebytes(public_key).decode() + "-----END PUBLIC KEY-----\n")
        for name, data in (("signed", signed), ("signature", signature)):
            with open(os.path.join(folder, name), "wb") as f:
                f.write(data)
        run = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pem, "-signature", os.path.join(folder, "signature"),
                              os.path.join(folder, "signed")], capture_output=True)
        return run.returncode == 0


class Standin:
    def __init__(self, vault, port, two_factor, new_device, scheme="http"):
        self.vault = vault
        self.base = f"{scheme}://127.0.0.1:{port}"
        self.two_factor = two_factor
        self.save = None
        self.new_device = new_device
        # A new revision each time it starts, so that a stand-in started
        # again is an account that changed.
        self.revision = int(time.time() * 1000)
        self.refresh_tokens = set()
        self.access_tokens = set()

    def token(self, form):
        grant = form.get("grant_type")
        account = self.vault["account"]
        if grant == "refresh_token":
            # Any of its own, so that a stand-in started again does not sign
            # the simulator's app out.
            if not form.get("refresh_token", "").startswith("kanarya-refresh-"):
                return 400, {"error": "invalid_grant"}
            return 200, self.issue(refresh=form["refresh_token"])
        if grant != "password":
            return 400, {"error": "unsupported_grant_type"}
        if form.get("username", "").strip().lower() != account["email"] or form.get("password") != account["serverHash"]:
            return 400, {"error": "invalid_grant", "error_description": "invalid_username_or_password",
                         "ErrorModel": {"Message": "Username or password is incorrect. Try again.", "Object": "error"}}
        if self.two_factor and form.get("twoFactorToken") != TWO_FACTOR_CODE:
            return 400, {"error": "invalid_grant", "error_description": "Two factor required.",
                         "TwoFactorProviders": ["0"], "TwoFactorProviders2": {"0": None},
                         "ErrorModel": {"Message": "Two-step token is invalid. Try again." if form.get("twoFactorToken") else "Two factor required.",
                                        "Object": "error"}}
        if self.new_device and not self.two_factor and form.get("newdeviceotp") != NEW_DEVICE_CODE:
            return 400, {"error": "device_error", "error_description": "New device verification required.",
                         "ErrorModel": {"Message": "new device verification required", "Object": "error"}}
        return 200, dict(self.issue(), **self.vault["token"], UserDecryptionOptions={
            "HasMasterPassword": True, "Object": "userDecryptionOptions",
            "MasterPasswordUnlock": {"Kdf": {"KdfType": self.vault["prelogin"]["kdf"],
                                             "Iterations": self.vault["prelogin"]["kdfIterations"],
                                             "Memory": self.vault["prelogin"]["kdfMemory"],
                                             "Parallelism": self.vault["prelogin"]["kdfParallelism"]},
                                     "MasterKeyEncryptedUserKey": self.vault["token"]["Key"],
                                     "Salt": account["email"]}})

    def issue(self, refresh=None):
        account = self.vault["account"]
        now = int(time.time())
        payload = {"nbf": now, "exp": now + 3600, "iss": self.base + "/identity", "client_id": "mobile",
                   "sub": account["userId"], "auth_time": now, "idp": "bitwarden", "premium": True,
                   "email": account["email"], "email_verified": True, "sstamp": account["securityStamp"],
                   "name": account["name"], "orgowner": [], "device": str(uuid.uuid4()),
                   "scope": ["api", "offline_access"], "amr": ["Application"]}
        access = b64url({"alg": "RS256", "typ": "JWT"}) + "." + b64url(payload) + ".kanarya-signature"
        refresh = refresh or "kanarya-refresh-" + uuid.uuid4().hex
        self.access_tokens.add(access)
        self.refresh_tokens.add(refresh)
        return {"access_token": access, "expires_in": 3600, "token_type": "Bearer",
                "refresh_token": refresh, "scope": "api offline_access"}

    STALE = "The cipher you are updating is out of date. Please save your work, sync your vault, and try again."
    KEPT = ("name", "notes", "favorite", "reprompt", "key", "login", "card", "identity", "secureNote", "sshKey",
            "fields", "passwordHistory", "folderId")

    def now(self):
        return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())

    def edit(self, cipher_id, body):
        """A write as the server takes one: refused when it was made from an
        older copy, and otherwise every field it sends taken as it came."""
        for cipher in self.vault["sync"]["ciphers"]:
            if cipher["id"] != cipher_id:
                continue
            if body.get("lastKnownRevisionDate") and body["lastKnownRevisionDate"] != cipher["revisionDate"]:
                return 400, {"message": self.STALE, "validationErrors": {"": [self.STALE]}, "object": "error"}
            for name in self.KEPT:
                if name in body:
                    cipher[name] = body[name]
            cipher["revisionDate"] = self.now()
            self.changed()
            return 200, cipher
        return 404, {"message": "Not found"}

    def create(self, body):
        cipher = {"object": "cipherDetails", "id": str(uuid.uuid4()), "organizationId": None, "type": body.get("type", 1),
                  "edit": True, "viewPassword": True, "organizationUseTotp": False, "creationDate": self.now(),
                  "revisionDate": self.now(), "deletedDate": None, "archivedDate": None, "attachments": None,
                  "collectionIds": [], "permissions": {"delete": True, "restore": True}}
        for name in self.KEPT:
            cipher[name] = body.get(name)
        self.vault["sync"]["ciphers"].append(cipher)
        self.changed()
        return 200, cipher

    def passkey_made(self, body):
        """What a registration returned, read as a relying party reads it:
        the client data, then the attestation's authenticator data with the
        id and the COSE key in it."""
        attestation, _ = cbor(base64.b64decode(body["attestation"]))
        data = attestation["authData"]
        length = int.from_bytes(data[53:55], "big")
        key, _ = cbor(data, 55 + length)
        if not client_says(body, "webauthn.create", MAKE_CHALLENGE) or attestation["fmt"] != "none" \
                or data[:32] != hashlib.sha256(b"localhost").digest() or data[32] & 0x45 != 0x45 \
                or (key[1], key[3], key[-1]) != (2, -7, 1):
            return False
        spki = bytes.fromhex(P256_SPKI) + b"\x04" + key[-2] + key[-3]
        self.vault.setdefault("passkeysMade", []).append({"id": base64.b64encode(data[55:55 + length]).decode(),
                                                          "publicKey": base64.b64encode(spki).decode()})
        self.changed()
        return True

    def passkey_used(self, body):
        """An assertion held to the public key the registration returned."""
        made = self.vault.get("passkeysMade")
        data, client = base64.b64decode(body["data"]), base64.b64decode(body["client"])
        if not made or not client_says(body, "webauthn.get", USE_CHALLENGE) or data[:32] != hashlib.sha256(b"localhost").digest():
            return False
        return verifies(base64.b64decode(made[-1]["publicKey"]), data + hashlib.sha256(client).digest(),
                        base64.b64decode(body["signature"]))

    def changed(self):
        self.revision = int(time.time() * 1000)
        if self.save:
            with open(self.save, "w") as f:
                json.dump(self.vault, f, indent=1, ensure_ascii=False)

    def config(self):
        return {"object": "config", "version": "2026.10.0", "gitHash": "standin", "server": None,
                "environment": {"vault": self.base, "api": self.base + "/api", "identity": self.base + "/identity",
                                "notifications": self.base + "/notifications", "sso": ""},
                "featureStates": {}, "push": {"pushTechnology": 0}, "settings": {"disableUserRegistration": True}}


def handler_for(standin):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def send(self, status, body, kind="application/json; charset=utf-8"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            print(f"{self.command} {urlparse(self.path).path} {status}", flush=True)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        def authorised(self):
            header = self.headers.get("Authorization", "")
            return header.startswith("Bearer ") and header.endswith(".kanarya-signature")

        def do_GET(self):
            path = urlparse(self.path).path.rstrip("/")
            if path == "/login":
                return self.send(200, LOGIN_PAGE, "text/html; charset=utf-8")
            if path == "/code":
                return self.send(200, CODE_PAGE, "text/html; charset=utf-8")
            if path == "/signup":
                return self.send(200, SIGNUP_PAGE, "text/html; charset=utf-8")
            if path == "/passkey":
                return self.send(200, PASSKEY_PAGE, "text/html; charset=utf-8")
            if path in ("/api/config", "/config"):
                return self.send(200, standin.config())
            if path.startswith("/api/") and not self.authorised():
                return self.send(401, {"message": "Unauthorized"})
            if path == "/api/sync":
                return self.send(200, standin.vault["sync"])
            if path == "/api/accounts/revision-date":
                return self.send(200, standin.revision)
            if path == "/api/accounts/profile":
                return self.send(200, standin.vault["sync"]["profile"])
            self.send(404, {"message": "Not found"})

        def do_POST(self):
            path = urlparse(self.path).path.rstrip("/")
            raw = self.body()
            if path in ("/identity/accounts/prelogin", "/identity/accounts/prelogin/password"):
                return self.send(200, standin.vault["prelogin"])
            if path == "/identity/connect/token":
                form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                status, answer = standin.token(form)
                return self.send(status, answer)
            if path == "/api/accounts/resend-new-device-otp":
                return self.send(200, b"", "text/plain")
            if path == "/api/accounts/key-management/user-key-id" and self.authorised():
                # Bitwarden's CLI 2026.9 sends one after its first sync, as a
                # migration of its own. Taken and forgotten.
                return self.send(200, b"", "text/plain")
            if path == "/login":
                # Whether what was submitted is one of the vault's logins for
                # this page, said and logged as yes or no, never the values.
                form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                logins = [i["login"] for i in standin.vault["plain"]["items"]
                          if i["login"] and any(u.startswith("http://localhost:8099") for u in i["login"].get("uris", []))]
                matched = any(form.get("username") == l.get("username") and form.get("password") == l.get("password")
                              for l in logins)
                print(f"login {'matched' if matched else 'did not match'}", flush=True)
                page = b"<!doctype html><h1>Matched</h1>" if matched else b"<!doctype html><h1>No match</h1>"
                return self.send(200, page, "text/html; charset=utf-8")
            if path == "/signup":
                form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                print(f"signed up, password of {len(form.get('password', ''))} characters", flush=True)
                return self.send(200, b"<!doctype html><h1>Signed up</h1>", "text/html; charset=utf-8")
            if path == "/code":
                form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                secrets = [i["login"]["totp"] for i in standin.vault["plain"]["items"]
                           if i["login"] and i["login"].get("totp")
                           and any(u.startswith("http://localhost:8099") for u in i["login"].get("uris", []))]
                matched = any(form.get("code") in totp(secret, time.time()) for secret in secrets)
                print(f"code {'matched' if matched else 'did not match'}", flush=True)
                page = b"<!doctype html><h1>Code matched</h1>" if matched else b"<!doctype html><h1>No match</h1>"
                return self.send(200, page, "text/html; charset=utf-8")
            if path == "/passkey/made":
                made = standin.passkey_made(json.loads(raw))
                print(f"passkey {'made' if made else 'refused'}", flush=True)
                return self.send(200, b"Passkey made" if made else b"Passkey refused", "text/plain")
            if path == "/passkey/used":
                used = standin.passkey_used(json.loads(raw))
                print(f"passkey {'verified' if used else 'did not verify'}", flush=True)
                return self.send(200, b"Signed in with the passkey" if used else b"The signature did not verify", "text/plain")
            if path.startswith("/api/") and not self.authorised():
                return self.send(401, {"message": "Unauthorized"})
            if path == "/api/ciphers":
                status, answer = standin.create(json.loads(raw or b"{}"))
                return self.send(status, answer)
            self.send(404, {"message": "Not found"})

        def do_PUT(self):
            path = urlparse(self.path).path.rstrip("/")
            raw = self.body()
            if not self.authorised():
                return self.send(401, {"message": "Unauthorized"})
            if path.startswith("/api/ciphers/"):
                status, answer = standin.edit(path.rsplit("/", 1)[1], json.loads(raw or b"{}"))
                return self.send(status, answer)
            self.send(404, {"message": "Not found"})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--vault", default="Tests/Fixtures/vault.json")
    parser.add_argument("--two-factor", action="store_true")
    parser.add_argument("--new-device", action="store_true")
    parser.add_argument("--tls", metavar="DIR")
    parser.add_argument("--save", metavar="FILE", help="the account as it stands after each write")
    args = parser.parse_args()
    with open(args.vault) as f:
        vault = json.load(f)
    standin = Standin(vault, args.port, args.two_factor, args.new_device, "https" if args.tls else "http")
    standin.save = args.save
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler_for(standin))
    if args.tls:
        cert, key = os.path.join(args.tls, "cert.pem"), os.path.join(args.tls, "key.pem")
        if not os.path.exists(cert):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-nodes", "-days", "30", "-subj", "/CN=standin", "-keyout", key, "-out", cert,
                            "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"standin on {standin.base}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())

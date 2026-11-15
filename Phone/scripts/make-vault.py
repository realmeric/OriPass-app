#!/usr/bin/env python3 -I
"""Writes Tests/Fixtures/vault.json: an invented Bitwarden account, encrypted
by the openssl command, as the server keeps it (prelogin, token, sync), with
the plaintext the phone must find in it beside. The master password is
"demo"; every other value is a canary that starts "kanarya-", so a search of
a disk, a log or a pasteboard finds it. Run from Phone/:

    scripts/make-vault.py [--argon2id OUT]

Random keys and IVs, so every run writes another file that means the same.
With --argon2id the master key is made by Argon2id at Bitwarden's defaults
(64 MiB, 3 iterations, 4 lanes) and the file is written to OUT instead."""
import base64, hashlib, json, os, subprocess, sys, tempfile, uuid

EMAIL = "kanarya@example.invalid"
PASSWORD = "demo"
ITERATIONS = 600_000
STAMP = "2026-10-20T10:00:00.000Z"
ARGON2 = "--argon2id" in sys.argv
OUT = sys.argv[sys.argv.index("--argon2id") + 1] if ARGON2 else "Tests/Fixtures/vault.json"


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout


def b64(b):
    return base64.b64encode(b).decode()


def b64url(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def enc(plain, key):
    """A type 2 string: AES-256-CBC and an HMAC-SHA256 over the IV and the
    ciphertext, both by openssl."""
    if plain is None:
        return None
    if isinstance(plain, str):
        plain = plain.encode()
    iv = os.urandom(16)
    ct = openssl("enc", "-aes-256-cbc", "-K", key[:32].hex(), "-iv", iv.hex(), data=plain)
    mac = openssl("mac", "-digest", "SHA256", "-macopt", "hexkey:" + key[32:].hex(), "-binary", "HMAC", data=iv + ct)
    return f"2.{b64(iv)}|{b64(ct)}|{b64(mac)}"


def kdf(*opts, name, length=32):
    args = ["kdf", "-binary", "-keylen", str(length)]
    for o in opts:
        args += ["-kdfopt", o]
    return openssl(*args, name)


def ident():
    return str(uuid.uuid4())


if ARGON2:
    ITERATIONS = 3
    master = kdf("pass:" + PASSWORD, "hexsalt:" + hashlib.sha256(EMAIL.encode()).hexdigest(), "iter:3",
                 "memcost:65536", "lanes:4", name="ARGON2ID")
else:
    master = kdf("digest:SHA256", "pass:" + PASSWORD, "salt:" + EMAIL, f"iter:{ITERATIONS}", name="PBKDF2")
stretched = kdf("digest:SHA256", "mode:EXPAND_ONLY", "hexkey:" + master.hex(), "info:enc", name="HKDF") + \
    kdf("digest:SHA256", "mode:EXPAND_ONLY", "hexkey:" + master.hex(), "info:mac", name="HKDF")
server_hash = b64(kdf("digest:SHA256", "hexpass:" + master.hex(), "hexsalt:" + PASSWORD.encode().hex(), "iter:1", name="PBKDF2"))
user_key = os.urandom(64)
org_key = os.urandom(64)
own_key = os.urandom(64)

with tempfile.TemporaryDirectory() as tmp:
    rsa = os.path.join(tmp, "rsa.pem")
    openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", rsa)
    private_der = openssl("pkey", "-in", rsa, "-outform", "DER")
    public_der = openssl("pkey", "-in", rsa, "-pubout", "-outform", "DER")
    with open(os.path.join(tmp, "pub.der"), "wb") as f:
        f.write(public_der)
    sealed_org_key = openssl("pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", os.path.join(tmp, "pub.der"),
                             "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha1",
                             "-pkeyopt", "rsa_mgf1_md:sha1", data=org_key)
    passkey_pem = os.path.join(tmp, "passkey.pem")
    openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", passkey_pem)
    passkey_der = openssl("pkey", "-in", passkey_pem, "-outform", "DER")
    passkey_public = openssl("pkey", "-in", passkey_pem, "-pubout", "-outform", "DER")

user_id, org_id, folder_id, collection_id = ident(), ident(), ident(), ident()
plain_items = []
ciphers = []


def login_part(key, username=None, password=None, uris=(), totp=None, passkey=None):
    part = {
        "username": enc(username, key), "password": enc(password, key),
        "passwordRevisionDate": None, "totp": enc(totp, key), "autofillOnPageLoad": None,
        "uris": [{"uri": enc(u, key), "uriChecksum": enc(b64(hashlib.sha256(u.encode()).digest()), key), "match": None}
                 for u in uris] or None,
        "fido2Credentials": None,
    }
    if passkey:
        part["fido2Credentials"] = [{k: (v if k == "creationDate" else enc(v, key)) for k, v in passkey.items()}]
    return part


def add(kind, name, *, key=user_key, own=False, org=False, folder=None, favorite=False, notes=None,
        login=None, card=None, identity=None, ssh=None, fields=(), history=(), deleted=False, plain_extra=None):
    cid = ident()
    item_key = own_key if own else key
    cipher = {
        "object": "cipherDetails", "id": cid, "organizationId": org_id if org else None,
        "folderId": folder, "type": kind, "name": enc(name, item_key), "notes": enc(notes, item_key),
        "favorite": favorite, "edit": True, "viewPassword": True, "organizationUseTotp": org,
        "revisionDate": STAMP, "creationDate": STAMP,
        "deletedDate": STAMP if deleted else None, "archivedDate": None, "reprompt": 0,
        "key": enc(own_key, key) if own else None,
        "login": login_part(item_key, **login) if login is not None else None,
        "card": {k: enc(v, item_key) for k, v in card.items()} if card else None,
        "identity": {k: enc(v, item_key) for k, v in identity.items()} if identity else None,
        "secureNote": {"type": 0} if kind == 2 else None,
        "sshKey": {k: enc(v, item_key) for k, v in ssh.items()} if ssh else None,
        "fields": [{"type": t, "name": enc(n, item_key), "value": enc(v, item_key), "linkedId": None}
                   for t, n, v in fields] or None,
        "passwordHistory": [{"password": enc(p, item_key), "lastUsedDate": STAMP} for p in history] or None,
        "attachments": None, "collectionIds": [collection_id] if org else [],
        "permissions": {"delete": True, "restore": True},
    }
    ciphers.append(cipher)
    plain = {"id": cid, "type": kind, "name": name, "notes": notes, "favorite": favorite, "deleted": deleted,
             "folderId": folder, "organizationId": cipher["organizationId"], "ownKey": own,
             "login": login, "card": card, "identity": identity, "sshKey": ssh,
             "fields": [{"type": t, "name": n, "value": v} for t, n, v in fields],
             "passwordHistory": list(history)}
    if login and login.get("passkey"):
        plain["login"] = dict(login, passkey={k: v for k, v in login["passkey"].items()})
    plain_items.append(plain)


add(1, "Stand-in login page", favorite=True,
    login={"username": "kanarya-user-1", "password": "kanarya-pass-1-Xr8", "uris": ["http://localhost:8099/login"],
           "totp": "otpauth://totp/Stand-in:kanarya-user-1?secret=KRSXG5CTMVRXEZLUKN2XAZLSKNSWG4TFOQ&issuer=Stand-in"})
add(1, "Stand-in second account",
    login={"username": "kanarya-user-7", "password": "kanarya-pass-7-Hd3", "uris": ["http://localhost:8099"]})
add(1, "Kanarya Mail", notes="kanarya-note-mail",
    login={"username": "kanarya-user-2@kanarya.example", "password": "kanarya-pass-2-Lq4",
           "uris": ["https://mail.kanarya.example/inbox", "androidapp://example.kanarya.mail"],
           "totp": "JBSWY3DPEHPK3PXP"},
    fields=[(0, "kanarya-field-name", "kanarya-field-1"), (1, "kanarya-hidden-name", "kanarya-hidden-1"), (2, "kanarya-flag", "true")],
    history=["kanarya-old-pass-2"])
add(1, "Kanarya Bank", own=True, folder=folder_id,
    login={"username": "kanarya-user-3", "password": "kanarya-pass-3-Zt2", "uris": ["https://bank.kanarya.example"]})
add(1, "Shared router", key=org_key, org=True,
    login={"username": "kanarya-user-4", "password": "kanarya-pass-4-Wn6", "uris": ["https://router.kanarya.example"]})
add(1, "Kanarya Passkey Site",
    login={"username": "kanarya-user-5", "uris": ["https://passkey.kanarya.example"],
           "passkey": {"credentialId": ident(), "keyType": "public-key", "keyAlgorithm": "ECDSA", "keyCurve": "P-256",
                       "keyValue": b64(passkey_der), "rpId": "passkey.kanarya.example", "rpName": "Kanarya Passkey Site",
                       "userHandle": b64url(b"kanarya-user-handle-5"), "userName": "kanarya-user-5",
                       "userDisplayName": "Kanarya Five", "counter": "0", "discoverable": "true", "creationDate": STAMP}})
add(1, "Old Kanarya", deleted=True,
    login={"username": "kanarya-user-6", "password": "kanarya-pass-6-Qp1", "uris": ["https://old.kanarya.example"]})
add(2, "Kanarya Note", notes="kanarya-note-1, with **bold** in it")
add(3, "Kanarya Card", card={"cardholderName": "Kanarya Kus", "brand": "Visa", "number": "4111111111111111",
                             "expMonth": "12", "expYear": "2030", "code": "123"})
add(4, "Kanarya Identity", identity={"title": "Mx", "firstName": "Kanarya", "lastName": "Kus",
                                     "email": "kanarya-identity@kanarya.example", "phone": "kanarya-phone",
                                     "city": "kanarya-city", "country": "TR"})
add(5, "Kanarya SSH", ssh={"privateKey": "kanarya-ssh-private", "publicKey": "kanarya-ssh-public",
                           "keyFingerprint": "kanarya-ssh-fingerprint"})

for p in plain_items:
    if p["login"] and p["login"].get("passkey"):
        p["login"]["passkey"]["publicKey"] = b64(passkey_public)

protected_user_key = enc(user_key, stretched)
protected_private_key = enc(private_der, user_key)
account_keys = {"publicKeyEncryptionKeyPair": {"wrappedPrivateKey": protected_private_key, "publicKey": b64(public_der),
                                               "signedPublicKey": None},
                "signatureKeyPair": None, "securityState": None, "object": "privateKeys"}
kdf_settings = {"kdfType": 1 if ARGON2 else 0, "iterations": ITERATIONS,
                "memory": 64 if ARGON2 else None, "parallelism": 4 if ARGON2 else None}

vault = {
    "account": {"email": EMAIL, "password": PASSWORD, "serverHash": server_hash, "userId": user_id,
                "name": "Kanarya", "securityStamp": "kanarya-stamp"},
    "prelogin": {"kdf": kdf_settings["kdfType"], "kdfIterations": ITERATIONS, "kdfMemory": kdf_settings["memory"],
                 "kdfParallelism": kdf_settings["parallelism"],
                 "kdfSettings": kdf_settings, "salt": EMAIL},
    "token": {"Key": protected_user_key, "PrivateKey": protected_private_key, "Kdf": kdf_settings["kdfType"],
              "KdfIterations": ITERATIONS, "KdfMemory": kdf_settings["memory"], "KdfParallelism": kdf_settings["parallelism"],
              "AccountKeys": account_keys},
    "sync": {
        "object": "sync",
        "profile": {
            "object": "profile", "id": user_id, "name": "Kanarya", "email": EMAIL, "emailVerified": True,
            "premium": True, "premiumFromOrganization": False, "culture": "en-US", "twoFactorEnabled": False,
            "key": protected_user_key, "privateKey": protected_private_key, "accountKeys": account_keys,
            "securityStamp": "kanarya-stamp", "forcePasswordReset": False, "usesKeyConnector": False,
            "avatarColor": None, "creationDate": STAMP, "verifyDevices": True,
            "organizations": [{
                "object": "profileOrganization", "id": org_id, "name": "Kanarya Family", "key": "4." + b64(sealed_org_key),
                "enabled": True, "status": 2, "type": 2, "useTotp": True, "usersGetPremium": True,
                "useEvents": False, "useGroups": False, "useDirectory": False, "usePolicies": False,
                "useSso": False, "selfHost": False, "seats": 6, "maxCollections": None, "maxStorageGb": 1,
                "hasPublicAndPrivateKeys": False, "permissions": {}, "keyConnectorEnabled": False,
                "userId": user_id, "organizationUserId": ident(), "productTierType": 1, "accessSecretsManager": False,
            }],
            "providers": [], "providerOrganizations": [],
        },
        "folders": [{"object": "folder", "id": folder_id, "name": enc("Kanarya Folder", user_key), "revisionDate": STAMP}],
        "collections": [{"object": "collectionDetails", "id": collection_id, "organizationId": org_id,
                         "name": enc("Kanarya Collection", org_key), "externalId": None, "readOnly": False,
                         "hidePasswords": False, "manage": False}],
        "ciphers": ciphers,
        "domains": None, "policies": [], "sends": [],
        "userDecryption": {"masterPasswordUnlock": {"kdf": kdf_settings, "masterKeyEncryptedUserKey": protected_user_key,
                                                    "salt": EMAIL}},
    },
    "plain": {"userKey": b64(user_key), "orgKey": b64(org_key), "folder": "Kanarya Folder",
              "collection": "Kanarya Collection", "items": plain_items},
}

with open(OUT, "w") as f:
    json.dump(vault, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"wrote {OUT}: {len(ciphers)} items")

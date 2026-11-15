#!/usr/bin/env python3 -I
"""Writes Tests/Fixtures/crypto.json: encrypted strings, a key derivation and
an RSA key made by the openssl command, so that the phone's Swift is held to
an implementation that is not this repository's. Every value is random or
invented. Run from Phone/: scripts/crypto-fixtures.py"""
import base64, json, os, subprocess, tempfile

def run(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout

def b64(b): return base64.b64encode(b).decode()

def type2(plain: bytes, enc: bytes, mac: bytes) -> str:
    iv = os.urandom(16)
    ct = run("enc", "-aes-256-cbc", "-K", enc.hex(), "-iv", iv.hex(), data=plain)
    tag = run("mac", "-digest", "SHA256", "-macopt", "hexkey:" + mac.hex(), "-binary", "HMAC", data=iv + ct)
    return f"2.{b64(iv)}|{b64(ct)}|{b64(tag)}"

key = os.urandom(64)
plain = "kanarya-sifre-7Qz!".encode()
password, email = b"kanarya demo", "Kanarya@Example.invalid "
salt = email.strip().lower().encode()
master = run("kdf", "-binary", "-keylen", "32", "-kdfopt", "digest:SHA256",
             "-kdfopt", "pass:" + password.decode(), "-kdfopt", "salt:" + salt.decode(),
             "-kdfopt", "iter:5000", "PBKDF2")
stretch = {}
for info in ("enc", "mac"):
    stretch[info] = run("kdf", "-binary", "-keylen", "32", "-kdfopt", "digest:SHA256",
                        "-kdfopt", "mode:EXPAND_ONLY", "-kdfopt", "hexkey:" + master.hex(),
                        "-kdfopt", "info:" + info, "HKDF")
server_hash = run("kdf", "-binary", "-keylen", "32", "-kdfopt", "digest:SHA256",
                  "-kdfopt", "hexpass:" + master.hex(), "-kdfopt", "hexsalt:" + password.hex(),
                  "-kdfopt", "iter:1", "PBKDF2")
user_key = os.urandom(64)

with tempfile.TemporaryDirectory() as tmp:
    pem = os.path.join(tmp, "k.pem")
    run("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", pem)
    pkcs8 = run("pkey", "-in", pem, "-outform", "DER")
    org_key = os.urandom(64)
    sealed = {}
    for md in ("sha1", "sha256"):
        sealed[md] = run("pkeyutl", "-encrypt", "-inkey", pem, "-pkeyopt", "rsa_padding_mode:oaep",
                         "-pkeyopt", "rsa_oaep_md:" + md, "-pkeyopt", "rsa_mgf1_md:" + md, data=org_key)

fixture = {
    "key": b64(key),
    "plain": plain.decode(),
    "type2": type2(plain, key[:32], key[32:]),
    "pbkdf2": {
        "password": password.decode(), "email": email, "iterations": 5000,
        "masterKey": b64(master), "enc": b64(stretch["enc"]), "mac": b64(stretch["mac"]),
        "serverHash": b64(server_hash),
        "userKey": b64(user_key),
        "protectedUserKey": type2(user_key, stretch["enc"], stretch["mac"]),
    },
    "rsa": {
        "privateKey": b64(pkcs8),
        "protectedPrivateKey": type2(pkcs8, user_key[:32], user_key[32:]),
        "orgKey": b64(org_key),
        "type4": "4." + b64(sealed["sha1"]),
        "type3": "3." + b64(sealed["sha256"]),
    },
}
with open("Tests/Fixtures/crypto.json", "w") as f:
    json.dump(fixture, f, indent=2)
    f.write("\n")
print("wrote Tests/Fixtures/crypto.json")

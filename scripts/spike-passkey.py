#!/usr/bin/python3
# OP-76: does `bw` keep a passkey it is handed, and keep it encrypted? On a
# real account, by hand, once.
#
# The app would make the key and hand it to `bw` as a member of
# login.fido2Credentials, trusting `bw` to encrypt it on the way out. Nothing
# has ever written that list. The fifteen passkeys in the vault were put
# there by other clients, and until this says yes the app makes none.
#
# What you type, in Terminal.app and not in a pane a session can read, with
# OriPass quit and `bw` logged in under the app's own folder as it is now:
#
#   scripts/spike-passkey.py
#
# It asks for the master password once, with getpass. The password goes to
# the child as the body of `POST /unlock` over a socketpair that only this
# script and that child hold, and is in no argument and no environment. The
# run takes under a minute.
#
# You are not asked to read the report. Every line is yes or no, a count, a
# status or the name of a key: no value of an item, not even the invented
# ones, and every line also passes `say`, which knows the password, the
# session and everything this run invented and withholds any line holding
# one. The report is docs/spikes/passkey-run.txt, the same text the terminal
# shows, ignored by git, and a session reads it for you.
#
# It writes to the vault. It makes two logins of its own, named "OriPass
# passkey spike" and a number, for the site spike.oripass.invalid, which does
# not exist. The keys on them are invented, are in this file, and open
# nothing. It touches no other item:
#
#   a  the child, its status, the unlock
#   b  a new login sent with a passkey on it, as a POST
#   c  a login with no passkey, and a passkey put on it, as a PUT
#   d  a second passkey on that login: is the first still there
#   e  a rename of that login, sent back whole: are both still there
#   f  a forced sync, and all of it read again, which is the server's word
#   g  bw's own file: is each key a cipher string, and is any invented value
#      in that file as it was sent
#   h  both logins deleted for good, each read again, and the lock
#
# If either login cannot be deleted the last lines say LEFT BEHIND and its
# name: delete it yourself, in the web vault, and from the trash.
#
# `scripts/spike-passkey.py --selftest` needs no `bw` and no account. It runs
# the same steps against a child of its own, once as `bw` is hoped to be and
# once for each way of failing, with invented values, and fails if a value
# comes out in a printed line or a failure comes out as a yes.

import base64
import getpass
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.normpath(os.path.join(HERE, "..", "docs", "spikes", "passkey-run.txt"))
BW = "/opt/homebrew/bin/bw"
DATA = os.path.expanduser("~/Library/Application Support/OriPass/bw")
HOST = "localhost:8087"
FD = 3
SITE = "spike.oripass.invalid"

# The keys `docs/notes.md` found on a member of fido2Credentials, every one a
# string, and what `MadePasskey` writes.
KEYS = ["credentialId", "keyType", "keyAlgorithm", "keyCurve", "keyValue", "rpId", "rpName", "userHandle",
        "userName", "userDisplayName", "counter", "discoverable", "creationDate"]
# What may stand in the file as it was sent: Bitwarden keeps this one date in
# the clear, by what its clients were read to do. Anything else is a no.
PLAIN = {"creationDate"}
# PKCS#8 on P-256 in URL-safe base64, as Bitwarden's clients write it, made
# with `openssl` for this file and used for nothing.
INVENTED_KEYS = [
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgzZuWN0124IR7Ep7uGmnxmhYHFG5fHtTnZ5dfjRW1dJah"
    "RANCAARepaUgbxoCw8LCfeTdDXnDlKoE6yslFsHwVPz92Mj9ThjxkP7XzYCUJflkapnxLlxtTbhcf8IJYihojgFB82qQ",
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgWrh3NynFxE4zYfN-m-MiwMKbsCiVuag__XxjrERUg5Wh"
    "RANCAARZFahoMMLoT2u2JQhKt7aGNAI3Tjd8xDBUFIwTRsFtkQkomgibGLM2fGfVyX0xHLYi78IZSdoFHOGDqX2jcGbl",
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgFHRLwRp34ssTEhPVwpQ0RfY9g4efS-ipilNBY9k1Sq-h"
    "RANCAATGW9e071oMUzQgp-XgwsZqoRh9o03PWFKsUofa4FZkCEEra-PAwHZvIHZ2c_8ZJ-dVmxZC8Jc8wAbqMcqkCmbU",
]

# ---- what may be printed ---------------------------------------------------

SECRETS = []        # the password, the session and every invented value
WITHHELD = [0]
LINES = []          # everything said, for the selftest to search
REPORT_FILE = [None]


def secret(text):
    if text and len(text) >= 4 and text not in SECRETS:
        SECRETS.append(text)


def say(line=""):
    """The one way a line leaves this script."""
    for part in str(line).split("\n"):
        if any(s in part for s in SECRETS):
            WITHHELD[0] += 1
            part = "WITHHELD: a line with a secret in it was about to be printed, and was not"
        LINES.append(part)
        print(part, flush=True)
        if REPORT_FILE[0]:
            REPORT_FILE[0].write(part + "\n")
            REPORT_FILE[0].flush()


def head(title):
    say()
    say("## " + title)


def yes(truth):
    return "yes" if truth else "no"


def sentence(body):
    """A refusal's own words, or how long the body was."""
    try:
        answer = json.loads(body)
    except ValueError:
        return "no envelope, %d bytes" % len(body)
    message = answer.get("message") if isinstance(answer, dict) else None
    return repr(message) if isinstance(message, str) and "BW_SESSION" not in message else "no sentence"


# ---- one child and the one connection to it --------------------------------

class Closed(Exception):
    """The other end closed, or said nothing in time."""


class Child:
    """`bw serve` with one end of a socketpair as descriptor 3, and the
    other end here. Nothing listens anywhere."""

    def __init__(self, argv, env):
        self.mine, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = b""
        self.unlocked = False
        self.exit = None
        handle, self.errors = tempfile.mkstemp(prefix="spike-passkey-", suffix=".err")
        os.close(handle)
        actions = [(os.POSIX_SPAWN_OPEN, 0, "/dev/null", os.O_RDONLY, 0),
                   (os.POSIX_SPAWN_OPEN, 1, "/dev/null", os.O_WRONLY, 0),
                   (os.POSIX_SPAWN_OPEN, 2, self.errors, os.O_WRONLY | os.O_TRUNC, 0o600)]
        number = theirs.fileno()
        if number == FD:
            os.set_inheritable(FD, True)
        else:
            actions.append((os.POSIX_SPAWN_DUP2, number, FD))
        self.pid = os.posix_spawn(argv[0], argv, env, file_actions=actions)
        theirs.close()

    def alive(self):
        if self.exit is not None:
            return False
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.exit = -1
            return False
        if pid == 0:
            return True
        self.exit = os.waitstatus_to_exitcode(status)
        return False

    def _fill(self, deadline):
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Closed("no answer in time")
            self.mine.settimeout(min(left, 0.25))
            try:
                data = self.mine.recv(65536)
            except socket.timeout:
                if not self.alive():
                    raise Closed("the child exited")
                continue
            except OSError as error:
                raise Closed("the connection failed (%s)" % type(error).__name__)
            if not data:
                raise Closed("the child closed the connection")
            self.buffer += data
            return

    def ask(self, method, path, body=None, within=120):
        """One request on the one connection: (status, body)."""
        if self.mine is None:
            raise Closed("this end is closed")
        request = "%s %s HTTP/1.1\r\nHost: %s\r\n" % (method, path, HOST)
        if body is not None:
            request += "Content-Type: application/json\r\nContent-Length: %d\r\n" % len(body)
        deadline = time.monotonic() + within
        try:
            self.mine.settimeout(within)
            self.mine.sendall(request.encode() + b"\r\n" + (body or b""))
        except OSError as error:
            raise Closed("the request could not be written (%s)" % type(error).__name__)
        while b"\r\n\r\n" not in self.buffer:
            self._fill(deadline)
        top, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = top.decode("latin-1").split("\r\n")
        try:
            status = int(lines[0].split(" ")[1])
        except (ValueError, IndexError):
            raise Closed("an answer that was not HTTP")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        if "chunked" in headers.get("transfer-encoding", "").lower():
            answer = b""
            while True:
                while b"\r\n" not in self.buffer:
                    self._fill(deadline)
                size, self.buffer = self.buffer.split(b"\r\n", 1)
                size = int(size.split(b";")[0], 16)
                while len(self.buffer) < size + 2:
                    self._fill(deadline)
                answer += self.buffer[:size]
                self.buffer = self.buffer[size + 2:]
                if size == 0:
                    break
        else:
            size = int(headers.get("content-length", "0"))
            while len(self.buffer) < size:
                self._fill(deadline)
            answer, self.buffer = self.buffer[:size], self.buffer[size:]
        return status, answer

    def end(self):
        """Lock it if it is open, close, kill. True when it was locked."""
        if self.unlocked and self.alive() and self.mine is not None:
            try:
                status, _ = self.ask("POST", "/lock", within=10)
                self.unlocked = status != 200
            except (Closed, ValueError, IndexError):
                pass
        locked = not self.unlocked
        if self.mine is not None:
            self.mine.close()
            self.mine = None
        began = time.monotonic()
        while self.alive() and time.monotonic() - began < 3:
            time.sleep(0.01)
        if self.alive():
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
            self.exit = -9
        try:
            os.unlink(self.errors)
        except OSError:
            pass
        return locked


# ---- what is sent and what is held to it -----------------------------------

def urlsafe(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def invented(key):
    """A member of fido2Credentials as the app would send it."""
    entry = {
        "credentialId": str(uuid.uuid4()),
        "keyType": "public-key",
        "keyAlgorithm": "ECDSA",
        "keyCurve": "P-256",
        "keyValue": key,
        "rpId": SITE,
        "rpName": SITE,
        "userHandle": urlsafe(os.urandom(16)),
        "userName": "spike-%s" % uuid.uuid4().hex[:12],
        "counter": "0",
        "discoverable": "true",
        "creationDate": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
    }
    entry["userDisplayName"] = entry["userName"]
    for name in ("credentialId", "keyValue", "userHandle", "userName"):
        secret(entry[name])
    return entry


def login(name, passkeys):
    """A new login, with the keys the app sends one with."""
    return {"type": 1, "name": name, "notes": None, "favorite": False, "fields": [], "passwordHistory": [],
            "reprompt": 0, "folderId": None,
            "login": {"uris": [{"uri": "https://" + SITE, "match": None}], "username": None, "password": None,
                      "totp": None, "fido2Credentials": passkeys}}


def item_of(body):
    try:
        data = json.loads(body).get("data")
    except (ValueError, AttributeError):
        return None
    return data if isinstance(data, dict) else None


def held(item):
    """The passkeys an item came back with, or None for no list at all."""
    found = ((item or {}).get("login") or {}).get("fido2Credentials")
    return found if isinstance(found, list) else None


def keeps(item, entries, label):
    """Whether `item` holds exactly `entries`, in order, each key as sent.
    Says counts and key names, and never what they held."""
    found = held(item)
    say("%s holds %s passkeys, and was sent %d" % (label, "no list of" if found is None else len(found), len(entries)))
    if found is None or len(found) != len(entries):
        return False
    faithful = True
    for n, (kept, sent) in enumerate(zip(found, entries), 1):
        wrong = sorted(k for k in KEYS if kept.get(k) != sent[k])
        extra = sorted(k for k in kept if k not in KEYS)
        say("%s passkey %d: of %d keys %d came back as sent%s%s"
            % (label, n, len(KEYS), len(KEYS) - len(wrong),
               "; not as sent: %s" % ", ".join(wrong) if wrong else "",
               "; keys it added: %s" % ", ".join(extra) if extra else ""))
        faithful = faithful and not wrong
    return faithful


CIPHER = re.compile(r"^[0-9]\.[A-Za-z0-9+/=]+\|[A-Za-z0-9+/=]+(\|[A-Za-z0-9+/=]+)?$")


def cipher_in(value, wanted):
    """The object with this id and a login, wherever bw's file keeps it."""
    if isinstance(value, dict):
        if value.get("id") == wanted and isinstance(value.get("login"), dict):
            return value
        value = list(value.values())
    if isinstance(value, list):
        for member in value:
            found = cipher_in(member, wanted)
            if found is not None:
                return found
    return None


def at_rest(path, id, entries, label):
    """What bw's own file holds for one item: whether each key is a cipher
    string, and how often each thing that was sent stands in it as it was."""
    try:
        with open(path, "rb") as held_file:
            whole = held_file.read()
        cipher = cipher_in(json.loads(whole), id)
    except (OSError, ValueError):
        say("%s bw's own file could not be read" % label)
        return False
    if cipher is None:
        say("%s bw's own file: the item was not found in it, %d bytes" % (label, len(whole)))
        return False
    kept = held(cipher) or []
    say("%s bw's own file holds %d passkeys, and was sent %d" % (label, len(kept), len(entries)))
    clean = len(kept) == len(entries)
    for n, entry in enumerate(kept, 1):
        encrypted = [k for k in KEYS if isinstance(entry.get(k), str) and CIPHER.match(entry[k])]
        bare = sorted(k for k in KEYS if k not in encrypted and k not in PLAIN)
        say("%s passkey %d in the file: %d of %d keys are cipher strings%s, keyValue among them: %s"
            % (label, n, len(encrypted), len(KEYS), "; not one: %s" % ", ".join(bare) if bare else "",
               yes("keyValue" in encrypted)))
        clean = clean and not bare
    for name in KEYS:
        if name in PLAIN or name in ("keyType", "keyAlgorithm", "keyCurve", "counter", "discoverable"):
            continue
        times = sum(whole.count(entry[name].encode()) for entry in entries)
        if times:
            say("%s %s as it was sent stands in the file %d times" % (label, name, times))
            clean = False
    say("%s every value that must be hidden is absent from the file as sent: %s" % (label, yes(clean)))
    return clean


# ---- the run ---------------------------------------------------------------

def spike(argv, env, ask_password, described, data_file):
    """Every step, then both logins gone and the lock, however it went."""
    state = {"child": None, "opened": False, "made": {}, "verdicts": {}, "left": []}
    try:
        steps(argv, env, ask_password, described, data_file, state)
    except (Closed, ValueError, KeyError, TypeError, OSError) as why:
        say("the run stopped early: %s" % type(why).__name__ + (": %s" % why if isinstance(why, Closed) else ""))
    finally:
        clear(state)
    return report(state)


def steps(argv, env, ask_password, described, data_file, state):
    verdicts = state["verdicts"]
    head("a. the child and the unlock")
    say("the child is started as: %s, with descriptor %d one end of a socketpair" % (described, FD))
    child = state["child"] = Child(argv, env)
    status, body = child.ask("GET", "/status", within=30)
    standing = ((json.loads(body).get("data") or {}).get("template") or {}).get("status")
    say("a. /status HTTP %d, %s" % (status, standing if standing in ("unauthenticated", "locked", "unlocked") else "something else"))
    if standing == "unauthenticated":
        say("a. bw is not logged in under the app's folder, so nothing can be asked")
        return
    password = ask_password()
    secret(password)
    status, answer = child.ask("POST", "/unlock", json.dumps({"password": password}).encode(), within=60)
    if status != 200:
        say("a. POST /unlock HTTP %d, %s" % (status, sentence(answer)))
        say("a. the password was not taken, and nothing was written")
        return
    child.unlocked = state["opened"] = True
    secret((item_of(answer) or {}).get("raw"))
    say("a. POST /unlock HTTP 200")
    del answer, password

    run = int(time.time()) % 100000
    first, second, third = (invented(key) for key in INVENTED_KEYS)

    head("b. a new login, sent with a passkey on it")
    name = "OriPass passkey spike %d a" % run
    status, answer = child.ask("POST", "/object/item", json.dumps(login(name, [first])).encode())
    made = item_of(answer)
    say("b. POST /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    created = made.get("id") if status == 200 and made else None
    if created:
        state["made"][created] = name
    verdicts["new login"] = bool(created) and keeps(made, [first], "b. the answer")

    head("c. a login with no passkey, and one put on it")
    name = "OriPass passkey spike %d b" % run
    status, answer = child.ask("POST", "/object/item", json.dumps(login(name, [])).encode())
    plain = item_of(answer)
    say("c. POST /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    edited = plain.get("id") if status == 200 and plain else None
    if not edited:
        verdicts["existing login"] = False
        return
    state["made"][edited] = name
    plain["login"]["fido2Credentials"] = [second]
    status, answer = child.ask("PUT", "/object/item/" + edited, json.dumps(plain).encode())
    say("c. PUT /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    current = item_of(answer) if status == 200 else None
    verdicts["existing login"] = keeps(current, [second], "c. the answer")
    if current is None:
        return

    head("d. a second passkey on the same login")
    current["login"]["fido2Credentials"] = (held(current) or []) + [third]
    status, answer = child.ask("PUT", "/object/item/" + edited, json.dumps(current).encode())
    say("d. PUT /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    current = item_of(answer) if status == 200 else None
    verdicts["a second keeps the first"] = keeps(current, [second, third], "d. the answer")
    if current is None:
        return

    head("e. a rename, with the object sent back whole")
    current["name"] = name + " renamed"
    state["made"][edited] = current["name"]
    status, answer = child.ask("PUT", "/object/item/" + edited, json.dumps(current).encode())
    say("e. PUT /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    verdicts["an edit keeps them"] = keeps(item_of(answer) if status == 200 else None, [second, third], "e. the answer")

    head("f. a forced sync, and all of it read again")
    status, answer = child.ask("POST", "/sync?force=true")
    say("f. POST /sync?force=true HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
    verdicts["the server has them"] = status == 200
    for id, entries, label in ((created, [first], "f. the new login"), (edited, [second, third], "f. the other login")):
        if not id:
            verdicts["the server has them"] = False
            continue
        status, answer = child.ask("GET", "/object/item/" + id)
        faithful = keeps(item_of(answer) if status == 200 else None, entries, label)
        verdicts["the server has them"] = verdicts["the server has them"] and faithful

    head("g. bw's own file")
    verdicts["encrypted in bw's file"] = True
    for id, entries, label in ((created, [first], "g. the new login:"), (edited, [second, third], "g. the other login:")):
        if not id or not at_rest(data_file, id, entries, label):
            verdicts["encrypted in bw's file"] = False


def clear(state):
    """Both logins deleted for good and read again, the vault locked and
    the child gone. Whatever this cannot delete is named."""
    child = state["child"]
    head("h. what is left")
    for id, name in state["made"].items():
        gone = False
        try:
            status, answer = child.ask("DELETE", "/object/item/%s?permanent=true" % id)
            say("h. DELETE for good HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
            status, _ = child.ask("GET", "/object/item/" + id)
            gone = status != 200
        except (Closed, ValueError, IndexError) as why:
            say("h. the delete could not be asked: %s" % why)
        say("h. the login is gone: %s" % yes(gone))
        if not gone:
            state["left"].append(name)
    if child is None:
        say("h. no child was started")
    elif child.end():
        say("h. locked: the last thing the vault was sent was POST /lock" if state["opened"]
            else "h. the vault was never opened by this run")
    else:
        say("h. NOT LOCKED BY THIS RUN: the child ended with the vault open, and the session went with it")


def report(state):
    head("the answer")
    wanted = ["new login", "existing login", "a second keeps the first", "an edit keeps them",
              "the server has them", "encrypted in bw's file"]
    for name in wanted:
        say("%s: %s" % (name, yes(state["verdicts"].get(name))))
    for name in state["left"]:
        say("LEFT BEHIND: %s. Delete it yourself, in the web vault, and from the trash." % name)
    if not state["opened"]:
        say("spike-passkey: the vault was not opened, so nothing was asked")
        return 1
    passed = all(state["verdicts"].get(name) for name in wanted)
    say("spike-passkey: %s" % ("yes, bw keeps a passkey it is handed, encrypted" if passed else "no, the card stops at the door"))
    return 0 if passed else 1


# ---- the selftest's child --------------------------------------------------

# Enough of `bw serve` to be asked everything above. What it "encrypts" is
# hashed, so that a value in bw's file is there only when a mode puts it there.
FAKE = r'''
import base64, hashlib, json, os, socket, sys, uuid
mode = os.environ.get("FAKE_MODE", "")
data_file = os.environ["FAKE_FILE"]
conn = socket.socket(fileno=3)
state = {"open": False}
items = {}
def seal(text):
    digest = base64.b64encode(hashlib.sha256(("selftest-" + text).encode()).digest()).decode()
    return "2.%s|%s|%s" % (digest[:22] + "==", digest, digest)
def at_rest(item):
    login = {k: v for k, v in item["login"].items() if k != "uris"}
    kept = []
    for entry in login.get("fido2Credentials") or []:
        kept.append({k: (v if k == "creationDate" or (mode == "plain" and k == "keyValue") else seal(v)) for k, v in entry.items()})
    login["fido2Credentials"] = kept
    return {"id": item["id"], "type": 1, "login": login}
def store():
    with open(data_file, "w") as out:
        json.dump({"global_selftest": 1, "user_selftest-id-0001_ciphers_ciphers": {i: at_rest(c) for i, c in items.items()}}, out)
def reply(status, payload):
    body = json.dumps(payload).encode()
    conn.sendall(("HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (status, len(body))).encode() + body)
def keep(sent, known):
    item = dict(sent)
    login = dict(item.get("login") or {})
    passkeys = login.get("fido2Credentials") or []
    if mode == "dropsOnCreate" and not known:
        passkeys = []
    if mode == "dropsOnEdit" and known:
        passkeys = []
    if mode == "replaces" and known:
        passkeys = passkeys[-1:]
    if mode == "mangles":
        passkeys = [dict(p, counter="1") for p in passkeys]
    if mode == "losesKey":
        passkeys = [{k: v for k, v in p.items() if k != "discoverable"} for p in passkeys]
    if mode == "renameDrops" and "renamed" in item.get("name", ""):
        passkeys = []
    login["fido2Credentials"] = passkeys
    item["login"] = login
    return item
held = b""
while True:
    while b"\r\n\r\n" not in held:
        data = conn.recv(65536)
        if not data:
            sys.exit(0)
        held += data
    top, held = held.split(b"\r\n\r\n", 1)
    lines = top.decode().split("\r\n")
    method, target = lines[0].split(" ")[:2]
    route = target.split("?")[0]
    headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:]}
    size = int(headers.get("content-length", "0"))
    while len(held) < size:
        held += conn.recv(65536)
    sent, held = held[:size], held[size:]
    name = route.rsplit("/", 1)[-1]
    if (method, route) == ("GET", "/status"):
        reply(200, {"success": True, "data": {"object": "template", "template": {"userEmail": "selftest-mail-Rv8", "status": "unlocked" if state["open"] else "locked"}}})
    elif (method, route) == ("POST", "/unlock"):
        given = json.loads(sent).get("password", "")
        if hashlib.sha256(given.encode()).hexdigest() == os.environ["FAKE_DIGEST"]:
            state["open"] = True
            key = "selftest-session-" + base64.b64encode(os.urandom(48)).decode()
            reply(200, {"success": True, "data": {"object": "message", "message": "export BW_" + "SESSION=\"%s\"" % key, "raw": key}})
        else:
            reply(400, {"success": False, "message": "Cryptography error, The decryption operation failed"})
    elif (method, route) == ("POST", "/lock"):
        state["open"] = False
        reply(200, {"success": True, "data": {"object": "message"}})
    elif not state["open"]:
        reply(400, {"success": False, "message": "Vault is locked."})
    elif (method, route) == ("POST", "/sync"):
        if mode == "serverForgets":
            for item in items.values():
                item["login"]["fido2Credentials"] = []
            store()
        reply(200, {"success": True, "data": {"object": "message"}})
    elif (method, route) == ("POST", "/object/item"):
        item = json.loads(sent)
        if mode == "refuses" and (item["login"].get("fido2Credentials")):
            reply(400, {"success": False, "message": "Invalid."})
            continue
        made = keep(item, False)
        made["id"] = str(uuid.uuid4())
        items[made["id"]] = made
        store()
        reply(200, {"success": True, "data": made})
    elif route.startswith("/object/item/") and name in items:
        if method == "GET":
            reply(200, {"success": True, "data": items[name]})
        elif method == "PUT":
            items[name] = keep(json.loads(sent), True)
            items[name]["id"] = name
            store()
            reply(200, {"success": True, "data": items[name]})
        elif mode == "sticks":
            reply(400, {"success": False, "message": "Not allowed."})
        else:
            del items[name]
            store()
            reply(200, {"success": True})
    else:
        reply(404, {"success": False, "message": "Not found."})
'''


def selftest():
    invented_password = "selftest-password-Qx7"
    failed = []

    def tour(mode, password=invented_password):
        directory = tempfile.mkdtemp(prefix="spike-passkey-")
        data_file = os.path.join(directory, "data.json")
        env = {"PATH": "/usr/bin:/bin", "FAKE_MODE": mode, "FAKE_FILE": data_file,
               "FAKE_DIGEST": hashlib.sha256(invented_password.encode()).hexdigest()}
        say()
        say("==== the fake child, %s" % (mode or "as bw is hoped to be"))
        mark = len(LINES)
        status = spike([sys.executable, "-c", FAKE], env, lambda: password, "the selftest's fake", data_file)
        try:
            os.unlink(data_file)
        except OSError:
            pass
        os.rmdir(directory)
        return status, LINES[mark:]

    def wants(lines, where, wanted):
        text = "\n".join(lines)
        for line in wanted:
            if line not in text:
                failed.append("not said, %s: %s" % (where, line))

    status, hoped = tour("")
    if status != 0:
        failed.append("an engine that keeps it was not a yes")
    wants(hoped, "of an engine that keeps it", [
        "a. POST /unlock HTTP 200",
        "b. the answer holds 1 passkeys, and was sent 1",
        "b. the answer passkey 1: of 13 keys 13 came back as sent",
        "d. the answer holds 2 passkeys, and was sent 2",
        "e. the answer holds 2 passkeys, and was sent 2",
        "f. the other login holds 2 passkeys, and was sent 2",
        "g. the new login: bw's own file holds 1 passkeys, and was sent 1",
        "g. the other login: passkey 2 in the file: 12 of 13 keys are cipher strings, keyValue among them: yes",
        "g. the other login: every value that must be hidden is absent from the file as sent: yes",
        "h. the login is gone: yes",
        "h. locked: the last thing the vault was sent was POST /lock",
        "encrypted in bw's file: yes",
        "spike-passkey: yes, bw keeps a passkey it is handed, encrypted",
    ])
    if "LEFT BEHIND" in "\n".join(hoped):
        failed.append("left something behind when everything went")

    # Each way of not keeping it: which step says so, and never a yes.
    for mode, line in (("plain", "g. the new login: passkey 1 in the file: 11 of 13 keys are cipher strings; not one: keyValue"),
                       ("plain", "g. the new login: keyValue as it was sent stands in the file 1 times"),
                       ("plain", "encrypted in bw's file: no"),
                       ("dropsOnCreate", "new login: no"),
                       ("dropsOnEdit", "existing login: no"),
                       ("replaces", "a second keeps the first: no"),
                       ("renameDrops", "an edit keeps them: no"),
                       ("mangles", "not as sent: counter"),
                       ("losesKey", "not as sent: discoverable"),
                       ("serverForgets", "the server has them: no"),
                       ("refuses", "new login: no")):
        status, lines = tour(mode)
        if status == 0:
            failed.append("%s was a yes" % mode)
        wants(lines, "of %s" % mode, [line, "spike-passkey: no, the card stops at the door"])
        wants(lines, "of %s" % mode, ["h. locked: the last thing the vault was sent was POST /lock"])

    status, stuck = tour("sticks")
    wants(stuck, "of an engine that will not delete", ["h. the login is gone: no", "LEFT BEHIND: OriPass passkey spike"])
    if status != 0:
        failed.append("a login left behind changed what the engine was found to do")

    status, wrong = tour("", password="selftest-not-the-password")
    if status == 0:
        failed.append("a wrong password was a yes")
    wants(wrong, "of a wrong password", ["a. POST /unlock HTTP 400", "'Cryptography error, The decryption operation failed'",
                                         "the password was not taken", "h. the vault was never opened by this run",
                                         "spike-passkey: the vault was not opened, so nothing was asked"])
    if any("/object/item" in line for line in wrong):
        failed.append("something was written with the vault shut")

    # The guard itself, on a line that never reaches the terminal as it is.
    before = WITHHELD[0]
    say("the guard is handed " + invented_password)
    if WITHHELD[0] != before + 1 or invented_password in LINES[-1]:
        failed.append("the guard let the password through")
    if before != 0:
        failed.append("%d lines of the run itself had a secret in them" % before)

    everything = "\n".join(LINES)
    for leaked in [invented_password, "selftest-session-", "selftest-mail-", "selftest-id-", SITE] + INVENTED_KEYS + SECRETS:
        if leaked in everything:
            failed.append("a value came through: %s" % leaked[:12])

    leftover = subprocess.run(["/usr/bin/pgrep", "-f", "FAKE_FILE|selftest-mail-Rv8"], capture_output=True).stdout
    if leftover.strip():
        failed.append("a fake child was left running")
    for line in failed:
        print("selftest: FAILED, " + line)
    if not failed:
        print("selftest: ok")
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if sys.argv[1:]:
        print("scripts/spike-passkey.py takes --selftest or nothing")
        return 2
    if not os.access(BW, os.X_OK):
        print("no bw at %s" % BW)
        return 2
    if subprocess.run(["/usr/bin/pgrep", "-x", "OriPass"], capture_output=True).stdout.strip():
        print("OriPass is running, and its own bw is using the same folder. Quit it and run this again.")
        return 2
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    REPORT_FILE[0] = open(REPORT, "w")

    def stop(number, _frame):
        raise SystemExit("stopped by signal %d" % number)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, stop)

    # Nothing inherited: a BW_SESSION exported in this terminal stays here.
    env = {"HOME": os.path.expanduser("~"), "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
           "BITWARDENCLI_APPDATA_DIR": DATA, "BW_NOINTERACTION": "true"}
    head("versions")
    version = subprocess.run([BW, "--version"], capture_output=True, env=env).stdout
    say("bw %s" % version.decode().strip()[:20])
    status = spike([BW, "serve", "--hostname", "fd+connected://%d" % FD], env,
                   lambda: getpass.getpass("Master password (not shown, not stored): "),
                   "bw serve --hostname fd+connected://%d" % FD, os.path.join(DATA, "data.json"))
    if WITHHELD[0]:
        status = 1
        say("%d lines were withheld because a secret was in them: that is a fault in this script, say so" % WITHHELD[0])
    say()
    say("Report written to docs/spikes/passkey-run.txt. You are not asked to read it: tell the session it is there.")
    return status


if __name__ == "__main__":
    sys.exit(main())

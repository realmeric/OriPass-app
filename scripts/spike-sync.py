#!/usr/bin/python3
# OP-84: does `bw` answer a list short behind a sync? On a real account, by
# hand, once.
#
# Read in 2026.9.1's source and never run: `getAllDecryptedUsingSdk` answers no
# rows when its decryption throws, with a 200, and does not cache them, so the
# next read has everything. Each list here is asked for straight behind a sync
# that moved something, which is the moment the app read it. No other script
# asks in that order.
#
# What you type, in Terminal.app and not in a pane a session can read, with
# OriPass quit and `bw` logged in under the app's own folder as it is now:
#
#   scripts/spike-sync.py
#
# It asks for the master password once, with getpass. The password goes to the
# child as the body of `POST /unlock` over a socketpair that only this script
# and that child hold, and is in no argument and no environment. The run takes
# about two minutes.
#
# You are not asked to read the report. Every line is a count, a status or a
# time, and never an id, a name or a value, and every line also passes `say`,
# which knows the password and the session and withholds any line holding one.
# The report is docs/spikes/sync-run.txt, the same text the terminal shows,
# ignored by git, and a session reads it for you.
#
# It writes to the vault, since a sync that finds nothing new changes nothing
# in `bw`. Each round makes one secure note of its own, named "OriPass sync
# spike" and a number, and deletes it for good. It touches no other item. If a
# note cannot be deleted the last lines say LEFT BEHIND: delete it yourself, in
# the web vault, and from the trash.
#
#   a  the child, its status, the unlock, and the lists straight behind it
#   b  eight rounds: a note made, a sync, the lists at once, at once again and
#      two seconds later, the note gone, and the same again
#   c  the lock, and how many of the reads were short
#
# `scripts/spike-sync.py --selftest` needs no `bw` and no account. It runs the
# same steps against a child of its own, steady, empty behind a sync and short
# behind a sync, and fails if a read is counted wrongly or a value is printed.

import getpass
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.normpath(os.path.join(HERE, "..", "docs", "spikes", "sync-run.txt"))
ROUNDS = 8
# The store's `VaultStore.secondRead`.
SECOND_READ = 2

# Its child, its connection and its guard on what is printed are this script's
# too.
spec = importlib.util.spec_from_file_location("spike_passkey", os.path.join(HERE, "spike-passkey.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
Child, Closed, say, secret, head, sentence = base.Child, base.Closed, base.say, base.secret, base.head, base.sentence
LINES, WITHHELD, REPORT_FILE, FD, BW, DATA = base.LINES, base.WITHHELD, base.REPORT_FILE, base.FD, base.BW, base.DATA


def rows(child, path):
    """How many rows a list route answers, and how long it took."""
    began = time.monotonic()
    status, body = child.ask("GET", path)
    took = time.monotonic() - began
    if status != 200:
        raise Closed("%s answered HTTP %d, %s" % (path.split("?")[0], status, sentence(body)))
    return len(json.loads(body)["data"]["data"]), took


def read(child, state, label, wanted):
    """Both lists, counted against what they should come to."""
    items, took = rows(child, "/list/object/items")
    trash, _ = rows(child, "/list/object/items?trash=true")
    state["reads"] += 1
    short = items < wanted[0] or trash < wanted[1]
    state["short"] += 1 if short else 0
    state["empty"] += 1 if short and items == 0 else 0
    say("%s: %d items, %d in the trash, %.3f s%s" % (label, items, trash, took, ", SHORT" if short else ""))
    return short


def behind_a_sync(child, state, label, wanted):
    began = time.monotonic()
    status, body = child.ask("POST", "/sync")
    say("%s: POST /sync HTTP %d, %.3f s%s" % (label, status, time.monotonic() - began,
                                             "" if status == 200 else ", %s" % sentence(body)))
    first = read(child, state, label + ", at once", wanted)
    read(child, state, label + ", at once again", wanted)
    time.sleep(SECOND_READ)
    later = read(child, state, label + ", two seconds on", wanted)
    state["healed"] += 1 if first and not later else 0


def steps(argv, env, ask_password, described, state):
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
    secret((json.loads(answer).get("data") or {}).get("raw"))
    say("a. POST /unlock HTTP 200")
    del answer, password

    first = rows(child, "/list/object/items")[0], rows(child, "/list/object/items?trash=true")[0]
    again = rows(child, "/list/object/items")[0], rows(child, "/list/object/items?trash=true")[0]
    say("a. straight behind the unlock: %d items, %d in the trash, and then %d and %d" % (first + again))
    wanted = max(first[0], again[0]), max(first[1], again[1])

    run = int(time.time()) % 100000
    for number in range(1, ROUNDS + 1):
        head("b. round %d of %d" % (number, ROUNDS))
        # Bitwarden's client lapses when it has gone a second unused, and a
        # sync from the window comes after a long quiet.
        if number % 2 == 0:
            time.sleep(1.5)
        note = {"type": 2, "name": "OriPass sync spike %d %d" % (run, number), "notes": None, "favorite": False,
                "fields": [], "passwordHistory": [], "reprompt": 0, "folderId": None, "secureNote": {"type": 0}}
        status, answer = child.ask("POST", "/object/item", json.dumps(note).encode())
        say("b. a note: POST /object/item HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
        if status != 200:
            return
        made = state["made"] = json.loads(answer)["data"]["id"]
        behind_a_sync(child, state, "b. with the note", (wanted[0] + 1, wanted[1]))
        status, answer = child.ask("DELETE", "/object/item/%s?permanent=true" % made)
        say("b. the note gone: DELETE HTTP %d%s" % (status, "" if status == 200 else ", %s" % sentence(answer)))
        if status != 200:
            return
        state["made"] = None
        behind_a_sync(child, state, "b. without it", wanted)


def spike(argv, env, ask_password, described):
    state = {"child": None, "opened": False, "made": None, "reads": 0, "short": 0, "empty": 0, "healed": 0}
    try:
        steps(argv, env, ask_password, described, state)
    except (Closed, ValueError, KeyError, TypeError, OSError) as why:
        say("the run stopped early: %s" % type(why).__name__ + (": %s" % why if isinstance(why, Closed) else ""))
    head("c. what is left, and the count")
    child = state["child"]
    if state["made"] and child is not None:
        try:
            status, _ = child.ask("DELETE", "/object/item/%s?permanent=true" % state["made"])
            if status == 200:
                state["made"] = None
        except Closed:
            pass
    if state["made"]:
        say("LEFT BEHIND: a note called OriPass sync spike. Delete it in the web vault, and from the trash.")
    locked = child.end() if child is not None else True
    if not state["opened"]:
        say("spike-sync: the vault was not opened, so nothing was asked")
        return 1
    say("c. locked: %s" % ("the last thing the vault was sent was POST /lock" if locked else "no, and the child was killed"))
    say("c. %d reads behind a sync, %d short, %d of those empty, %d back whole two seconds on"
        % (state["reads"], state["short"], state["empty"], state["healed"]))
    if state["short"]:
        say("spike-sync: yes, bw answers a list short behind a sync")
    else:
        say("spike-sync: no read came back short, so this run does not prove the cause")
    return 0


FAKE = r'''
import json, os, socket, sys
mode, digest = os.environ.get("FAKE_MODE", ""), os.environ["FAKE_DIGEST"]
connection = socket.socket(fileno=3)
unlocked, owed, notes = False, 0, {}
items = [{"id": "selftest-id-%d" % n, "name": "selftest-name-%d" % n} for n in range(5)]

def reply(status, payload):
    body = json.dumps(payload).encode()
    connection.sendall(b"HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n" % (status, len(body)) + body)

buffer = b""
while True:
    while b"\r\n\r\n" not in buffer:
        got = connection.recv(65536)
        if not got:
            sys.exit(0)
        buffer += got
    top, buffer = buffer.split(b"\r\n\r\n", 1)
    lines = top.decode().split("\r\n")
    method, target = lines[0].split(" ")[:2]
    size = next((int(l.split(":")[1]) for l in lines if l.lower().startswith("content-length")), 0)
    while len(buffer) < size:
        buffer += connection.recv(65536)
    body, buffer = buffer[:size], buffer[size:]
    route = target.split("?")[0]
    if route == "/status":
        reply(200, {"success": True, "data": {"template": {"status": "unlocked" if unlocked else "locked"}}})
    elif route == "/unlock":
        import hashlib
        if hashlib.sha256(json.loads(body)["password"].encode()).hexdigest() != digest:
            reply(400, {"success": False, "message": "Cryptography error, The decryption operation failed"})
        else:
            unlocked = True
            reply(200, {"success": True, "data": {"raw": "selftest-session-Kp2"}})
    elif route == "/lock":
        unlocked = False
        reply(200, {"success": True})
    elif route == "/sync":
        owed = 2 if mode else 0
        reply(200, {"success": True, "data": {"title": "Syncing complete."}})
    elif route == "/list/object/items":
        trash = "trash" in target
        rows = [] if trash else items + list(notes.values())
        if owed:
            owed -= 1
            rows = [] if mode == "empties" else rows[1:]
        reply(200, {"success": True, "data": {"object": "list", "data": rows}})
    elif route == "/object/item":
        made = dict(json.loads(body), id="selftest-id-note")
        notes[made["id"]] = made
        reply(200, {"success": True, "data": made})
    elif route.startswith("/object/item/"):
        notes.pop(route.rsplit("/", 1)[-1], None)
        reply(200, {"success": True})
    else:
        reply(404, {"success": False, "message": "Not found."})
'''


def selftest():
    import hashlib
    invented = "selftest-password-Qx7"
    failed = []

    def tour(mode, password=invented):
        env = {"PATH": "/usr/bin:/bin", "FAKE_MODE": mode, "FAKE_DIGEST": hashlib.sha256(invented.encode()).hexdigest()}
        say()
        say("==== the fake child, %s" % (mode or "steady"))
        mark = len(LINES)
        status = spike([sys.executable, "-c", FAKE], env, lambda: password, "the selftest's fake")
        return status, LINES[mark:]

    def wants(lines, where, wanted):
        text = "\n".join(lines)
        for line in wanted:
            if line not in text:
                failed.append("not said, %s: %s" % (where, line))

    reads = ROUNDS * 2 * 3
    _, steady = tour("")
    wants(steady, "of a steady engine", ["a. straight behind the unlock: 5 items, 0 in the trash, and then 5 and 0",
                                         "c. %d reads behind a sync, 0 short, 0 of those empty, 0 back whole" % reads,
                                         "spike-sync: no read came back short",
                                         "c. locked: the last thing the vault was sent was POST /lock"])
    _, empties = tour("empties")
    wants(empties, "of an engine that answers empty", [
        "c. %d reads behind a sync, %d short, %d of those empty, %d back whole" % (reads, ROUNDS * 2, ROUNDS * 2, ROUNDS * 2),
        "spike-sync: yes, bw answers a list short behind a sync"])
    _, short = tour("short")
    wants(short, "of an engine that answers short", [
        "c. %d reads behind a sync, %d short, 0 of those empty, %d back whole" % (reads, ROUNDS * 2, ROUNDS * 2)])
    status, wrong = tour("", password="selftest-not-the-password")
    if status == 0:
        failed.append("a wrong password was a yes")
    wants(wrong, "of a wrong password", ["a. POST /unlock HTTP 400", "spike-sync: the vault was not opened"])
    if any("LEFT BEHIND" in line for line in LINES):
        failed.append("left a note behind")
    before = WITHHELD[0]
    say("the guard is handed " + invented)
    if WITHHELD[0] != before + 1 or before != 0:
        failed.append("the guard did not stand")
    everything = "\n".join(LINES)
    for leaked in (invented, "selftest-session-", "selftest-id-", "selftest-name-", "OriPass sync spike 1"):
        if leaked in everything:
            failed.append("a value came through: %s" % leaked[:12])
    for line in failed:
        print("selftest: FAILED, " + line)
    if not failed:
        print("selftest: ok")
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        global SECOND_READ
        SECOND_READ = 0
        return selftest()
    if sys.argv[1:]:
        print("scripts/spike-sync.py takes --selftest or nothing")
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
    say("bw %s" % subprocess.run([BW, "--version"], capture_output=True, env=env).stdout.decode().strip()[:20])
    status = spike([BW, "serve", "--hostname", "fd+connected://%d" % FD], env,
                   lambda: getpass.getpass("Master password (not shown, not stored): "),
                   "bw serve --hostname fd+connected://%d" % FD)
    if WITHHELD[0]:
        status = 1
        say("%d lines were withheld because a secret was in them: that is a fault in this script, say so" % WITHHELD[0])
    say()
    say("Report written to docs/spikes/sync-run.txt. You are not asked to read it: tell the session it is there.")
    return status


if __name__ == "__main__":
    sys.exit(main())

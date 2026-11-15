#!/usr/bin/python3
"""A stand-in for `bw`, for the tests. Never the real one.

    standin-bw.py serve --hostname fd+connected://<n>
    standin-bw.py config server <address>
    standin-bw.py login [email] [--passwordenv NAME] [--method N] [--apikey]
    standin-bw.py logout
    standin-bw.py --version

It reads `standin.json` from the directory it sits in:

    fixtures   a directory of Tests/Fixtures
    log        a file that gets one line per request: METHOD PATH BODY
    unlocked   start with the vault open, for a test of the connection that
               is not about the unlock. The real one never does
    password   the master password /unlock accepts; any, when left out
    exitAfter  seconds after which it exits by itself
    loggedOut  refuse to serve at all, as the real one does
    slow       seconds before it answers its first request, which is the
               one that asks whether it is up: a node that is slow to start
    dies       a sentence `serve` says on standard error before it exits
               at once with status 1: a `bw` that could not start
    mute       read every request and say nothing
    deaf       answer the first request, which is the one that asks whether
               it is up, and say nothing to any after it
    stubborn   ignore SIGTERM and the other end closing, as none ever did
    lingers    seconds between the other end closing and its exit: 2 when
               left out, which is what the real one took
    chunked    answer with Transfer-Encoding: chunked
    split      send the body in two halves with a pause between
    host       the one Host it answers to, as a version with another rule would
    free       the account has no Premium, so `POST /archive/item` is refused
    emptyAfterSync
               how many reads of `/list/object/items`, of either list, answer
               with no rows behind each `/sync`, as `getAllDecryptedUsingSdk`
               in 2026.9.1's source answers when its decryption throws. Read
               and never seen (`docs/notes.md`, "When a list comes back
               short")

It serves the one socket it was handed, already connected, as descriptor
<n>, and nothing else: it listens nowhere and makes no file. That is what
2026.9.1 did on 2026-10-11 (`docs/spikes/fd-2026-10.md`), and so is the rest
of how it behaves there. Requests are answered one after another over that
connection for as long as it lives, no answer says `Connection: close`, and
when the other end closes it exits by itself with status 0, two seconds
later. Two requests written before the first is answered were never tried
on the real one; here they are answered in the order they were written.

Three files beside it change what it does from the next request on, for a
test that wants an engine to fail while it is open. None was seen of the
real one. `mute`: it reads every request and says nothing. `hang-up`: it
closes the connection with no answer and does not exit. `short`: it
promises more bytes than it sends, and then closes the connection.

What it answers is what 2026.9.1 answered on 2026-10-10 and, written to, on
2026-10-11, as far as those runs went (`docs/spikes/bw-2026-10.md`). A
refusal is HTTP 400 with the envelope: "Vault is locked." from a locked
child, "Cryptography error, The decryption operation failed" for a wrong
password, "Unknown template object." for a template it does not have, which
`item.sshkey` is. A child is opened by `POST /unlock` and by nothing else:
the real one is also opened by a session in `BW_SESSION`, which the app has
not handed a child since OP-66, so this one does not read the variable.

It remembers, for as long as it runs, which items are in the trash, which
are archived and which are gone, starting from the fixtures. A `DELETE`
answers `{"success": true}` and no item. `POST /restore/item` on an item
that is not in the trash is "Cipher is not in trash.", except for an
archived one, which it takes out of the archive: that is this app's guess
at the way out, and the real one was never asked, since the account that
ran could not archive. An item deleted for good is "Not found." to every
route after it. A `PUT` whose `revisionDate` is older than the fixture's
for that item is refused as the server refused one, in the long sentence of
`refused-out-of-date.json`, and one that sends no date is taken. With
`free`, an archive is "Premium status is required to use this feature.",
which is what the real one said on a free account.

A `PUT` or a `POST` of an item answers `item.json`, whatever it was sent,
except for `login.fido2Credentials`, which comes back as it went. That is a
guess at the real one's habit and no more, and `scripts/spike-passkey.py` is
what asks it.

Like the real one with origin protection on, it answers only a request whose
Host is `localhost`, `127.0.0.1`, `[::1]` or this Mac's name, each with
`:8087` after it, and none that carries an Origin: 403 and nine bytes that
are no envelope, after which the connection is still open. The real one's
nine were counted and not printed; here they are "Forbidden", the status's
own word, which is that long. No Host at all is 400, and what the real one
does with the connection then was not read: this one closes it.

For `login` it says what `scripts/spike-login.py` recorded the real one
saying (`login-recorded.json`), and which of them is chosen by the email's
first half, as the spike's server chose: `authenticator@`, `emailed@`,
`both@`, `keyonly@`, `device@`. Every start of it adds its arguments to
`arguments.log` beside it, one JSON array a line.

    password      the master password `login` accepts; any, when left out
    code          the code a second step or a new device accepts; any, when left out
    clientSecret  the secret `login --apikey` accepts
    unreachable   `login` finds no server
    silent        `login` says nothing and does not exit
"""
import json, os, re, signal, socket, sys, threading, time

here = os.path.dirname(os.path.abspath(__file__))
try:
    config = json.load(open(os.path.join(here, "standin.json")))
except OSError:
    config = {}

with open(os.path.join(here, "arguments.log"), "a") as arguments:
    arguments.write(json.dumps(sys.argv[1:]) + "\n")

signed_in = os.path.join(here, "signed-in")
server_file = os.path.join(here, "server")
signed_out = os.path.join(here, "signed-out")
logged_out = os.path.exists(signed_out) or (config.get("loggedOut") and not os.path.exists(signed_in))

if sys.argv[1:2] == ["logout"]:
    # What the real one says was not recorded: this is the stand-in's own.
    if logged_out:
        print("You are not logged in.")
        sys.exit(1)
    if os.path.exists(signed_in):
        os.remove(signed_in)
    open(signed_out, "w").close()
    print("You have logged out.")
    sys.exit(0)

if sys.argv[1:2] == ["status"]:
    name = "status-unauthenticated" if logged_out else "status-locked"
    answer = json.load(open(os.path.join(config["fixtures"], name + ".json")))
    print(json.dumps(answer if logged_out else answer["data"]["template"]))
    sys.exit(0)

if sys.argv[1:2] in (["config"], ["login"]):
    recorded = json.load(open(os.path.join(config["fixtures"], "login-recorded.json")))
    server = open(server_file).read() if os.path.exists(server_file) else "https://vault.bitwarden.com"
    asks = os.environ.get("BW_NOINTERACTION") != "true"

    def fill(text, typed=""):
        return (text.replace("$HOST$", server.split("//")[-1]).replace("$SERVER$", server)
                .replace("$TYPED$", typed))

    def end(name):
        answer = recorded[name]
        if "message" in answer:
            answer["message"] = fill(answer["message"])
        print(json.dumps(answer))
        sys.exit(0 if answer["success"] else 1)

    def ask(name):
        """The prompt on standard error, and a line from standard input. The
        real one sits at its prompt for ever when the input ends."""
        if not asks:
            end("code-required")
        sys.stderr.write(fill(recorded["noise"]) + recorded["prompt-" + name])
        sys.stderr.flush()
        line = sys.stdin.readline()
        if not line:
            time.sleep(3600)
        typed = line.rstrip("\n")
        sys.stderr.write(fill(recorded["echo-" + name], typed))
        sys.stderr.flush()
        return typed

    def option(flag):
        return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else None

    if sys.argv[1] == "config":
        if not logged_out:
            end("logout-required")
        address = sys.argv[3]
        if address in ("null", "bitwarden.com", "https://bitwarden.com"):
            if os.path.exists(server_file):
                os.remove(server_file)
        else:
            open(server_file, "w").write(address)
        end("saved")

    if not logged_out:
        end("already")
    if config.get("silent"):
        time.sleep(3600)
    if "--apikey" in sys.argv:
        if not os.environ.get("BW_CLIENTID"):
            end("client-id-required")
        if not os.environ["BW_CLIENTID"].startswith("user"):
            end("apikey-organisation")
    else:
        taken = {"--passwordenv", "--method", "--code"}
        words = [a for i, a in enumerate(sys.argv[2:], 2)
                 if not a.startswith("--") and sys.argv[i - 1] not in taken]
        email = words[0] if words else ""
        if "@" not in email:
            end("email-invalid")
        password = os.environ.get(option("--passwordenv") or "")
        if not password:
            end("password-required")
    if option("--method") is not None and option("--method") not in ("0", "1", "2", "3", "6", "7"):
        end("bad-method")
    if server.startswith("http://"):
        end("insecure")
    if config.get("unreachable"):
        end("unreachable")
    if "--apikey" in sys.argv:
        if os.environ.get("BW_CLIENTSECRET") != config.get("clientSecret"):
            end("apikey-wrong")
    else:
        if password != config.get("password", password):
            end("wrong-password")
        who = email.split("@")[0]
        names = {"0": "Authenticator App", "1": "Email"}
        methods = {"authenticator": ["0"], "emailed": ["1"], "both": ["0", "1"]}.get(who, [])
        if who == "keyonly":
            end("no-providers")
        if methods:
            chosen = option("--method") if option("--method") in methods else None
            if chosen is None and len(methods) == 1:
                chosen = methods[0]
            if chosen is None:
                if not asks:
                    end("no-provider-selected")
                sys.stderr.write(fill(recorded["noise"]) + recorded["prompt-method"].replace(
                    "$METHODS$", " \n  ".join(names[m] for m in methods) + " "))
                sys.stderr.flush()
                time.sleep(3600)
            typed = ask("code")
            if typed != config.get("code", typed) or not typed:
                end("bad-code")
        if who == "device":
            typed = ask("device")
            if typed != config.get("code", typed) or not typed:
                end("bad-device-code")
    open(signed_in, "w").close()
    if os.path.exists(signed_out):
        os.remove(signed_out)
    end("ok")

if "--version" in sys.argv:
    print(config.get("version", "2026.9.1"))
    sys.exit(0)

if logged_out:
    sys.stderr.write("You are not logged in.\n")
    sys.exit(1)

if config.get("dies"):
    sys.stderr.write(config["dies"] + "\n")
    sys.exit(1)

hostname = sys.argv[sys.argv.index("--hostname") + 1]
if not hostname.startswith("fd+connected://"):
    sys.stderr.write("The stand-in serves a connected socket and nothing else.\n")
    sys.exit(1)
connection = socket.socket(fileno=int(hostname[len("fd+connected://"):]))
state = {"unlocked": bool(config.get("unlocked")), "empty": 0}


def fixture(name):
    return open(os.path.join(config["fixtures"], name + ".json"), "rb").read()


def refuse(name):
    return 400, fixture(name)


def attached(headers, body):
    """The filename of the one part of a multipart body, as it was sent, or
    None when the part's head is not the two lines it has to be."""
    kind = headers.get("content-type", "")
    if not kind.startswith("multipart/form-data; boundary="):
        return None
    opening = b"--" + kind.split("boundary=", 1)[1].encode() + b"\r\n"
    if not body.startswith(opening) or b"\r\n\r\n" not in body:
        return None
    head = body[len(opening):].split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace").split("\r\n")
    if len(head) != 2 or not head[1].startswith("Content-Type: "):
        return None
    found = re.fullmatch(r'Content-Disposition: form-data; name="file"; filename="([^"\\\x00-\x1f\x7f]*)"', head[0])
    return found.group(1) if found else None


def held():
    """Every item the fixtures have, by id."""
    items = {}
    for name in ("list-items", "list-trash"):
        for item in json.loads(fixture(name))["data"]["data"]:
            items[item["id"]] = item
    return items


shelves = {}


def shelf(name):
    """The ids in the trash, in the archive or gone, read from the fixtures
    the first time one is asked for."""
    if not shelves:
        shelves["trash"] = {i for i, item in held().items() if item.get("deletedDate")}
        shelves["archive"] = {i for i, item in held().items() if item.get("archivedDate")}
        shelves["gone"] = set()
    return shelves[name]


def written(body):
    """The item the fixture holds, with any passkeys it was sent."""
    sent = (json.loads(body or b"{}").get("login") or {}).get("fido2Credentials")
    if not sent:
        return fixture("item")
    answer = json.loads(fixture("item"))
    answer["data"]["login"]["fido2Credentials"] = sent
    return json.dumps(answer).encode()


def item(method, route, target, body):
    """The routes that name one item."""
    known = route.rsplit("/", 1)[-1]
    if known in shelf("gone"):
        return refuse("refused-not-found")
    if route.startswith("/archive/item/"):
        if config.get("free"):
            return refuse("refused-premium")
        shelf("archive").add(known)
    elif route.startswith("/restore/item/"):
        if known not in shelf("trash") | shelf("archive"):
            return refuse("refused-not-in-trash")
        shelf("trash").discard(known)
        shelf("archive").discard(known)
    elif method == "DELETE":
        shelf("gone" if "permanent=true" in target.split("?")[-1] and "?" in target else "trash").add(known)
        return 200, fixture("deleted")
    elif method == "PUT":
        sent = json.loads(body or b"{}").get("revisionDate")
        theirs = held().get(known, {}).get("revisionDate")
        if sent and theirs and sent < theirs:
            return refuse("refused-out-of-date")
        return 200, written(body)
    return 200, fixture("item")


def answer(method, target, body, headers={}):
    route = target.split("?")[0]
    if route == "/status":
        return 200, fixture("status-unlocked" if state["unlocked"] else "status-locked")
    if route == "/unlock" and method == "POST":
        sent = json.loads(body or b"{}").get("password")
        if not sent or sent != config.get("password", sent):
            return refuse("refused-password")
        state["unlocked"] = True
        return 200, fixture("unlock")
    if route == "/lock" and method == "POST":
        state["unlocked"] = False
        return 200, fixture("lock")
    if route == "/generate":
        return 200, fixture("generate")
    if not state["unlocked"]:
        return refuse("refused-locked")
    if route == "/sync":
        state["empty"] = config.get("emptyAfterSync", 0)
        return 200, fixture("sync")
    if route == "/list/object/items":
        if state["empty"]:
            state["empty"] -= 1
            return 200, b'{"success":true,"data":{"object":"list","data":[]}}'
        return 200, fixture("list-trash" if "trash" in target.split("?")[-1] and "?" in target else "list-items")
    if route == "/list/object/folders":
        return 200, fixture("list-folders")
    if route == "/list/object/collections":
        return 200, fixture("list-collections")
    if route.startswith("/object/totp/"):
        return refuse("refused-premium")
    if route.startswith("/object/folder"):
        return 200, fixture("folder")
    if route.startswith("/object/template/"):
        name = "template-" + route[len("/object/template/"):]
        if not os.path.exists(os.path.join(config["fixtures"], name + ".json")):
            return refuse("refused-template")
        return 200, fixture(name)
    if route == "/attachment" and attached(headers, body) is None:
        return 400, b'{"success":false,"message":"Malformed part header"}'
    if route.startswith(("/object/item/", "/restore/item/", "/archive/item/")):
        return item(method, route, target, body)
    if route == "/object/item":
        return 200, written(body)
    if route.startswith("/attachment"):
        return 200, fixture("item")
    return 404, b'{"success":false,"message":"Not found."}'


def allowed(headers):
    """The real one's rule, read in its serve command: the port is `--port`
    or 8087, on a socket file too, and the names are compared in lower case."""
    names = ("localhost", "127.0.0.1", "[::1]", socket.gethostname().lower())
    hosts = [config["host"]] if config.get("host") else [n + ":8087" for n in names]
    return "origin" not in headers and headers.get("host", "").lower() in hosts


def turn_away(headers):
    """403 and nine bytes that are no envelope, and the connection goes on.
    The first run counted ten because its `echo` put a newline after them.
    What the real one sends with the 400 was not read: no body here, and
    the connection closed."""
    if headers.get("host", "").strip():
        connection.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 9\r\n\r\nForbidden")
        return True
    connection.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
    return False


def gone():
    """The other end has closed, or this one has. The real one took two
    seconds over it and exited with status 0."""
    if config.get("stubborn"):
        time.sleep(3600)
    time.sleep(config.get("lingers", 2))
    os._exit(0)


def read(data):
    """One request off the front of what has been read, and what is left."""
    while b"\r\n\r\n" not in data:
        got = connection.recv(65536)
        if not got:
            gone()
        data += got
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    method, target, _ = lines[0].split(" ")
    headers = {k.lower(): v.strip() for k, v in (line.split(":", 1) for line in lines[1:] if ":" in line)}
    length = int(headers.get("content-length", 0))
    while len(body) < length:
        got = connection.recv(65536)
        if not got:
            gone()
        body += got
    return method, target, headers, body[:length], body[length:]


def marked(name):
    return os.path.exists(os.path.join(here, name))


def serve(method, target, headers, body):
    """Answers one request. False when the connection is closed after it."""
    if config.get("log"):
        with open(config["log"], "a") as log:
            sent = body.decode() if "multipart" not in headers.get("content-type", "") else "file %s" % attached(headers, body)
            log.write("%s %s %s\n" % (method, target, sent))
    if not allowed(headers):
        return turn_away(headers)
    status, payload = answer(method, target, body, headers)
    reason = "OK" if status == 200 else "Bad Request"
    if config.get("chunked"):
        connection.sendall(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" % (status, reason)).encode())
        for start in range(0, len(payload), 37):
            piece = payload[start:start + 37]
            connection.sendall(b"%x\r\n%s\r\n" % (len(piece), piece))
            time.sleep(0.001)
        connection.sendall(b"0\r\n\r\n")
    elif config.get("split") or marked("short"):
        promised = len(payload) + (10 if marked("short") else 0)
        connection.sendall(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (status, reason, promised)).encode())
        half = len(payload) // 2
        connection.sendall(payload[:half])
        time.sleep(0.05)
        connection.sendall(payload[half:])
        return not marked("short")
    else:
        connection.sendall(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (status, reason, len(payload))).encode() + payload)
    return True


if config.get("stubborn"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if config.get("exitAfter") is not None:
    threading.Timer(config["exitAfter"], lambda: os._exit(0)).start()
rest = b""
answered = 0
while True:
    method, target, headers, body, rest = read(rest)
    if config.get("mute") or marked("mute") or (config.get("deaf") and answered):
        continue
    if not answered and config.get("slow"):
        time.sleep(config["slow"])
    answered += 1
    if marked("hang-up"):
        connection.close()
        time.sleep(3600)
    if not serve(method, target, headers, body):
        connection.close()
        gone()

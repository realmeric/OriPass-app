#!/usr/bin/python3
# OP-64: can `bw serve` be spoken to over one connected socket handed to it
# at birth, with no socket file and no session in its environment? On a
# real account, by hand.
#
# It met the real `bw` on 2026-10-11 and ran clean on its first try.
#
# What you type, in Terminal.app and not in a pane a session can read, with
# OriPass quit and `bw` logged in under the app's own folder as it is now:
#
#   scripts/spike-fd.py
#
# It asks for the master password once, with getpass, a few seconds in. The
# password goes to the child as the body of `POST /unlock` over a socketpair
# that only this script and that child hold. It is in no argument and no
# environment, this script's or the child's. The run takes about two
# minutes, most of it one wait of ten seconds and one of sixty at the end,
# by which time the vault is locked again and the password dropped.
#
# You are not asked to read the report. Everything printed is a fact, a
# count or a timing: a string in an answer is printed as "string(n)" with
# its length, except the state words, the CLI's own sentence when it
# refuses, and header names. Every line also passes `say`, which knows the
# password and each session key this run was given and withholds any line
# that holds one. The report is docs/spikes/fd-run.txt, the same text the
# terminal shows, ignored by git, and a session reads it for you.
#
# It makes no write to the vault and no socket file. It starts `bw serve`
# several times, each with one end of a socketpair as descriptor 3:
#
#   a  whether such a child starts and answers /status, and how fast
#   b  whether the one connection holds: at once, twenty times, after ten
#      idle seconds and after sixty, and whether it is ever told to close
#   c  the unlock by password over it, and what another process of yours
#      can see of the session afterwards (ps, the kernel's copy of the
#      arguments and environment, lsof)
#   d  the first list, and so the whole of spawn, status, unlock, list
#   e  lock and unlock again on the same connection, three times, and what
#      a locked child that is kept holds as far as ps and lsof show
#   f  whether the child goes by itself when this script closes its end
#   g  a wrong password, and a request with `Host: localhost`
#   h  the lock for real and the child killed, however the run ends
#
# `scripts/spike-fd.py --selftest` needs no `bw` and no account. It runs
# the same steps against a child of its own, a few lines of Python that
# speak enough HTTP on descriptor 3, with an invented password, and fails
# if that password or a session the fake made comes out in a printed line.

import ctypes
import getpass
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.normpath(os.path.join(HERE, "..", "docs", "spikes", "fd-run.txt"))
BW = "/opt/homebrew/bin/bw"
DATA = os.path.expanduser("~/Library/Application Support/OriPass/bw")
RUN = os.path.expanduser("~/Library/Application Support/OriPass/run")
HOST = "localhost:8087"
FD = 3

# ---- what may be printed ---------------------------------------------------

SECRETS = []        # the password and every session key, as text
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


KEEP = {"status": {"unauthenticated", "locked", "unlocked"}, "object": None, "success": None}


def shape(v, key=None):
    """Keys, types and lengths. Values never."""
    if isinstance(v, dict):
        return {k: shape(x, k) for k, x in v.items()}
    if isinstance(v, list):
        inner = {}
        for x in v:
            s = shape(x, key)
            if isinstance(s, dict):
                inner.update({k: t for k, t in s.items() if k not in inner})
        return {"array": len(v), "of": inner}
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, (int, float)):
        return "number"
    if key in KEEP and (KEEP[key] is None or v in KEEP[key]):
        return v
    # The sentence of a refusal is kept. The answer to a good unlock is not:
    # its message quotes the session key as lines to paste in a shell.
    if key == "message" and "BW_SESSION" not in v:
        return v
    return "string(%d)" % len(v)


def shaped(body):
    try:
        return json.dumps(shape(json.loads(body)), sort_keys=True)
    except ValueError:
        return "not JSON, %d bytes" % len(body)


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
        self.saw_close = 0
        self.headers = set()
        self.keep_alive = set()
        self.unlocked = False
        self.exit = None
        handle, self.errors = tempfile.mkstemp(prefix="spike-fd-", suffix=".err")
        os.close(handle)
        # Descriptor 3 in the child is their end. Everything else this
        # script holds is close-on-exec, as Python opens it.
        actions = [(os.POSIX_SPAWN_OPEN, 0, "/dev/null", os.O_RDONLY, 0),
                   (os.POSIX_SPAWN_OPEN, 1, "/dev/null", os.O_WRONLY, 0),
                   (os.POSIX_SPAWN_OPEN, 2, self.errors, os.O_WRONLY | os.O_TRUNC, 0o600)]
        number = theirs.fileno()
        if number == FD:
            os.set_inheritable(FD, True)
        else:
            actions.append((os.POSIX_SPAWN_DUP2, number, FD))
        self.started = time.monotonic()
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

    def last_words(self):
        try:
            with open(self.errors, errors="replace") as said:
                lines = [l.strip() for l in said.read().splitlines() if l.strip()]
        except OSError:
            return ""
        return lines[-1][:200] if lines else ""

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

    def ask(self, method, path, body=None, host=HOST, within=120):
        """One request on the one connection: (status, body, seconds)."""
        if self.mine is None:
            raise Closed("this end is closed")
        request = "%s %s HTTP/1.1\r\nHost: %s\r\n" % (method, path, host)
        if body is not None:
            request += "Content-Type: application/json\r\nContent-Length: %d\r\n" % len(body)
        began = time.monotonic()
        try:
            self.mine.settimeout(within)
            self.mine.sendall(request.encode() + b"\r\n" + (body or b""))
        except OSError as error:
            raise Closed("the request could not be written (%s)" % type(error).__name__)
        deadline = began + within
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
        self.headers |= set(headers)
        if "keep-alive" in headers:
            self.keep_alive.add(headers["keep-alive"][:40])
        if "close" in headers.get("connection", "").lower():
            self.saw_close += 1
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
        elif "content-length" not in headers and "close" in headers.get("connection", "").lower():
            # A body with no length ends where the connection does.
            try:
                while True:
                    self._fill(deadline)
            except Closed:
                answer, self.buffer = self.buffer, b""
        else:
            size = int(headers.get("content-length", "0"))
            while len(self.buffer) < size:
                self._fill(deadline)
            answer, self.buffer = self.buffer[:size], self.buffer[size:]
        return status, answer, time.monotonic() - began

    def still_open(self):
        """Whether the child has closed its end, without sending anything."""
        if self.mine is None:
            return False
        self.mine.setblocking(False)
        try:
            return self.mine.recv(1, socket.MSG_PEEK) != b""
        except (BlockingIOError, InterruptedError):
            return True
        except OSError:
            return False

    def let_go(self):
        """Close this end and nothing else."""
        if self.mine is not None:
            self.mine.close()
            self.mine = None

    def gone_within(self, seconds):
        """Seconds until the child had exited, or None if it had not."""
        began = time.monotonic()
        while time.monotonic() - began < seconds:
            if not self.alive():
                return time.monotonic() - began
            time.sleep(0.005)
        return None

    def end(self):
        """Lock it if it is open, close, kill. Safe to call twice."""
        locked = True
        if self.unlocked and self.alive() and self.mine is not None:
            try:
                status, _, _ = self.ask("POST", "/lock", within=10)
                self.unlocked = status != 200
            except (Closed, ValueError, IndexError):
                pass
        if self.unlocked:
            locked = False
        self.let_go()
        if self.alive():
            if self.gone_within(0.5) is None:
                os.kill(self.pid, signal.SIGKILL)
                self.gone_within(5)
        try:
            os.unlink(self.errors)
        except OSError:
            pass
        return locked


# ---- what another process can see of a child --------------------------------

def run(argv, within=30):
    try:
        return subprocess.run(argv, capture_output=True, timeout=within).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None


def kernel_copy(pid):
    """The arguments and the environment the kernel keeps for a process,
    which is where `ps eww` reads them: sysctl kern.procargs2."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        mib = (ctypes.c_int * 3)(1, 49, pid)      # CTL_KERN, KERN_PROCARGS2
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
            return None
        held = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, held, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
            return None
        return held.raw[:size.value]
    except (OSError, AttributeError):
        return None


def count(haystack, needle):
    return "could not be read" if haystack is None else str(haystack.count(needle.encode()))


def from_outside(child, label, sessions, password):
    """What ps, the kernel and lsof say of the child. Counts only."""
    everything = run(["/bin/ps", "eww", "-p", str(child.pid)])
    arguments = run(["/bin/ps", "-o", "command=", "-p", str(child.pid)])
    kernel = kernel_copy(child.pid)
    say("%s ps eww from another process: the name BW_SESSION appears %s times" % (label, count(everything, "BW_SESSION")))
    for n, session in enumerate(sessions, 1):
        say("%s session %d of this child: in ps eww %s times, in its arguments %s, in kern.procargs2 %s"
            % (label, n, count(everything, session), count(arguments, session), count(kernel, session)))
    say("%s the master password: in ps eww %s times, in its arguments %s, in kern.procargs2 %s"
        % (label, count(everything, password), count(arguments, password), count(kernel, password)))
    say("%s kern.procargs2: %s, the name BW_SESSION in it %s times"
        % (label, "could not be read" if kernel is None else "%d bytes" % len(kernel), count(kernel, "BW_SESSION")))
    memory = run(["/bin/ps", "-o", "rss=", "-p", str(child.pid)])
    say("%s resident memory: %s" % (label, "could not be read" if not memory or not memory.strip() else "%d MB" % (int(memory.split()[0]) // 1024)))
    # -F prints a field a line: f the descriptor, t its kind, n its name,
    # T what state a TCP socket is in.
    listing = run(["/usr/sbin/lsof", "-n", "-P", "-p", str(child.pid), "-F", "ftnT"], within=60)
    if listing is None:
        say("%s lsof could not be run" % label)
        return
    files = []
    for line in listing.decode(errors="replace").splitlines():
        if line.startswith("f"):
            files.append({"t": "?", "n": "", "T": ""})
        elif files and line[:1] in ("t", "n"):
            files[-1][line[0]] = line[1:]
        elif files and line.startswith("TST="):
            files[-1]["T"] = line[4:]
    kinds = {}
    for held in files:
        kinds[held["t"]] = kinds.get(held["t"], 0) + 1
    sockets = [f for f in files if f["t"] == "unix"]
    say("%s lsof: %d descriptors by kind %s" % (label, len(files), json.dumps(kinds, sort_keys=True)))
    say("%s lsof: unix sockets %d, of them with a path (a socket file) %d, TCP sockets listening %d, paths under the run directory %d"
        % (label, len(sockets), sum(1 for f in sockets if f["n"].startswith("/")),
           sum(1 for f in files if f["T"] == "LISTEN"), sum(1 for f in files if f["n"].startswith(RUN))))
    say("%s lsof: files open under bw's own folder: %s"
        % (label, sorted({os.path.basename(f["n"]) for f in files if f["n"].startswith(DATA)}) or "none"))


# ---- the run ---------------------------------------------------------------

def spawn(argv, env):
    return Child(argv, env)


def first_status(child):
    """Seconds from the spawn to the first answer on descriptor 3."""
    try:
        status, body, _ = child.ask("GET", "/status", within=30)
    except Closed as why:
        say("   %s, exit status %s, and its last words were: %s" % (why, child.exit, child.last_words() or "nothing"))
        return None
    return time.monotonic() - child.started, status, body


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def spike(argv, env, password, described, waits=(10, 60), patience=5):
    """Every step, against whatever `argv` starts, and then the lock,
    however the steps ended. `password` is asked for when it is needed."""
    state = {"child": None, "dirty": False, "opened": False, "password": None}
    try:
        return steps(argv, env, password, described, waits, patience, state)
    finally:
        child = state["child"]
        if child is not None and not child.end():
            state["dirty"] = True
        if state["dirty"] and state["password"]:
            # A child ended with the vault open and nothing locked after it.
            # One more child, opened and locked, ends that session for real.
            try:
                last = spawn(argv, env)
                status = 0
                if first_status(last) is not None:
                    status, body, _ = last.ask("POST", "/unlock", json.dumps({"password": state["password"]}).encode(), within=60)
                    if status == 200:
                        last.unlocked = True
                        secret(json.loads(body)["data"]["raw"])
                state["dirty"] = not last.end() or status != 200
            except (Closed, ValueError, KeyError, TypeError, OSError):
                pass
        state["password"] = None
        head("h. how it was left")
        if not state["opened"]:
            say("h. the vault was never opened by this run, and no child of it is alive")
        elif state["dirty"]:
            say("h. NOT LOCKED BY THIS RUN: a child ended with the vault open and no lock could be sent after it. "
                "The session key was in that child and in this script and nowhere else, and both are gone.")
        else:
            say("h. locked: the last thing the vault was sent was POST /lock, answered 200, and no child of this run is alive")


def steps(argv, env, ask_password, described, waits, patience, state):
    say("the child is started as: %s, with descriptor %d one end of a socketpair" % (described, FD))
    say("BW_SESSION in the environment it is given: %s" % ("yes" if "BW_SESSION" in env else "no"))

    head("a. a child on a connected socket, three runs, no session")
    child = None
    for n in (1, 2, 3):
        child = state["child"] = spawn(argv, env)
        first = first_status(child)
        if first is None:
            say("a. run %d: the child did not answer on descriptor %d" % (n, FD))
            say("a. nothing else can be asked of a child that does not answer")
            return 1
        seconds, status, body = first
        say("a. run %d: spawn to the first /status %.3f s, HTTP %d, %s" % (n, seconds, status, shaped(body)))
        if n < 3:
            child.end()

    head("b. does the connection hold (the first half; the idle waits are last)")
    try:
        status, _, seconds = child.ask("GET", "/status")
        say("b. a second request on the same connection, at once: HTTP %d in %.3f s" % (status, seconds))
        times = []
        for _ in range(20):
            status, _, seconds = child.ask("GET", "/status")
            times.append(seconds)
            if status != 200:
                break
        say("b. twenty requests in a row: %d answered, fastest %.3f s, median %.3f s, slowest %.3f s"
            % (len(times), min(times), median(times), max(times)))
    except Closed as why:
        say("b. THE CONNECTION DID NOT HOLD: %s" % why)
    say("b. answers that said Connection: close so far: %d" % child.saw_close)
    say("b. header names in its answers: %s" % sorted(child.headers))
    say("b. Keep-Alive headers it sent: %s" % (sorted(child.keep_alive) or "none"))

    head("g. a wrong password, and a Host with no port")
    try:
        wrong = json.dumps({"password": "not-the-password-%d" % (time.time_ns() % 100000)}).encode()
        status, body, seconds = child.ask("POST", "/unlock", wrong)
        say("g. POST /unlock with a wrong password: HTTP %d in %.3f s, %s" % (status, seconds, sentence(body)))
        status, body, _ = child.ask("GET", "/status")
        say("g. /status after it: HTTP %d, %s" % (status, shaped(body)))
    except Closed as why:
        say("g. the wrong password could not be asked: %s" % why)
    try:
        status, body, _ = child.ask("GET", "/status", host="localhost")
        say("g. GET /status with Host: localhost: HTTP %d, %d bytes" % (status, len(body)))
        time.sleep(0.2)
        say("g. the connection after that refusal: %s" % ("still open" if child.still_open() else "closed by the child"))
    except Closed as why:
        say("g. Host: localhost was answered with no HTTP at all: %s" % why)
    child.end()
    state["child"] = None

    head("the master password")
    password = state["password"] = ask_password()
    secret(password)
    body = json.dumps({"password": password}).encode()

    head("c, d. three cold runs: spawn, status, unlock, the first list")
    sessions = []
    for n in (1, 2, 3):
        child = state["child"] = spawn(argv, env)
        first = first_status(child)
        if first is None:
            say("d. run %d: the child did not answer" % n)
            return 1
        to_status = first[0]
        try:
            status, answer, to_unlock = child.ask("POST", "/unlock", body)
        except Closed as why:
            say("c. run %d: the unlock was not answered: %s" % (n, why))
            return 1
        if status != 200:
            say("c. run %d: POST /unlock HTTP %d in %.3f s, %s" % (n, status, to_unlock, sentence(answer)))
            say("c. the password was not taken, so nothing after this can be asked")
            return 1
        child.unlocked = state["opened"] = True
        try:
            session = json.loads(answer)["data"]["raw"]
        except (ValueError, KeyError, TypeError):
            session = ""
        secret(session)
        sessions = [session] if session else []
        say("c. run %d: POST /unlock over the connection: HTTP %d in %.3f s, %s" % (n, status, to_unlock, shaped(answer)))
        say("c. run %d: the session key at data.raw is %d characters" % (n, len(session)))
        try:
            status, answer, to_list = child.ask("GET", "/list/object/items")
            rows = json.loads(answer).get("data", {}).get("data", []) if status == 200 else []
            say("d. run %d: the first list HTTP %d in %.3f s, %d items" % (n, status, to_list, len(rows)))
            del rows, answer
            status, answer, again = child.ask("GET", "/list/object/items")
            del answer
            say("d. run %d: the second list HTTP %d in %.3f s" % (n, status, again))
            say("d. run %d: finger to first row, less the finger: spawn to status %.3f + unlock %.3f + list %.3f = %.3f s"
                % (n, to_status, to_unlock, to_list, to_status + to_unlock + to_list))
        except Closed as why:
            say("d. run %d: THE CONNECTION DID NOT HOLD after the unlock: %s" % (n, why))
            return 1
        if n == 1:
            head("c. what another process of yours can see of the unlocked child")
            from_outside(child, "c.", sessions, password)
            head("f. this end closed while the vault is open, as a crash would")
            child.let_go()
            gone = child.gone_within(patience)
            if gone is None:
                say("f. unlocked: THE CHILD WAS STILL RUNNING %d s after its only connection closed, and was killed" % patience)
                state["dirty"] = True
            else:
                say("f. unlocked: the child exited by itself %.3f s after this end closed, exit status %s" % (gone, child.exit))
                # It went with the vault open. The two runs after it each
                # unlock and lock, which is what ends a session for real.
                state["dirty"] = True
            child.unlocked = False
            child.end()
            head("c, d. the other two cold runs")
        elif n == 2:
            status, _, seconds = child.ask("POST", "/lock")
            child.unlocked = status != 200
            state["dirty"] = state["dirty"] and status != 200
            say("f. run 2: POST /lock HTTP %d in %.3f s" % (status, seconds))
            child.let_go()
            gone = child.gone_within(patience)
            if gone is None:
                say("f. locked: THE CHILD WAS STILL RUNNING %d s after its only connection closed, and was killed" % patience)
            else:
                say("f. locked: the child exited by itself %.3f s after this end closed, exit status %s" % (gone, child.exit))
            child.end()
    state["child"] = child

    head("e. lock and unlock again on the same connection, three times")
    seen = list(sessions)
    for n in (1, 2, 3):
        try:
            status, answer, seconds = child.ask("POST", "/lock")
            child.unlocked = status != 200
            if status == 200:
                state["dirty"] = False
            say("e. round %d: POST /lock HTTP %d in %.3f s, %s" % (n, status, seconds, shaped(answer)))
            status, answer, _ = child.ask("GET", "/list/object/items")
            say("e. round %d: a list from the locked child: HTTP %d, %s" % (n, status, sentence(answer)))
            status, answer, _ = child.ask("GET", "/status")
            say("e. round %d: /status of the locked child: HTTP %d, %s, the same process: %s"
                % (n, status, shaped(answer), "yes" if child.alive() else "NO"))
            if n == 1:
                head("e. what another process of yours can see of the locked child that was kept")
                from_outside(child, "e. locked:", seen, password)
                say("e. what it holds in memory while locked cannot be seen from outside, and nothing is said of it")
                head("e. and open again")
            status, answer, seconds = child.ask("POST", "/unlock", body)
            child.unlocked = status == 200
            session = ""
            if status == 200:
                try:
                    session = json.loads(answer)["data"]["raw"]
                except (ValueError, KeyError, TypeError):
                    pass
            secret(session)
            say("e. round %d: POST /unlock on the same connection, the child not restarted: HTTP %d in %.3f s, a session key of %d characters, %s"
                % (n, status, seconds, len(session), "the same as the one before" if session in seen else "one not seen before"))
            if session and session not in seen:
                seen.append(session)
            status, answer, seconds = child.ask("GET", "/list/object/items")
            del answer
            say("e. round %d: the first list after it: HTTP %d in %.3f s" % (n, status, seconds))
        except Closed as why:
            say("e. round %d: THE CONNECTION DID NOT HOLD: %s" % (n, why))
            break

    head("h. the lock for real, with the password no longer needed")
    try:
        status, _, seconds = child.ask("POST", "/lock")
        child.unlocked = status != 200
        if status == 200:
            state["dirty"] = False
        say("h. POST /lock HTTP %d in %.3f s" % (status, seconds))
    except Closed as why:
        say("h. the lock could not be sent on this connection: %s" % why)
    # Python cannot overwrite a string. Once the lock is answered the names
    # are dropped, the lines below never hold either, and the process ends
    # inside two minutes.
    del body
    password = None
    if not child.unlocked and not state["dirty"]:
        state["password"] = None

    head("b. does the connection hold, idle, on the locked child that is left")
    for wait in waits:
        say("   (waiting %s s)" % wait)
        time.sleep(wait)
        open_before = child.still_open()
        try:
            status, _, seconds = child.ask("GET", "/status")
            say("b. after %s s idle: HTTP %d in %.3f s on the same connection" % (wait, status, seconds))
        except Closed as why:
            say("b. after %s s idle: THE CONNECTION DID NOT HOLD (%s; before the request it looked %s)"
                % (wait, why, "open" if open_before else "closed"))
            break
    say("b. answers that said Connection: close, over the whole life of this child: %d" % child.saw_close)
    say("b. Keep-Alive headers it sent: %s" % (sorted(child.keep_alive) or "none"))

    head("f. this end closed on the locked child that was kept")
    child.let_go()
    gone = child.gone_within(patience)
    if gone is None:
        say("f. kept and locked: THE CHILD WAS STILL RUNNING %d s after its only connection closed, and was killed" % patience)
    else:
        say("f. kept and locked: the child exited by itself %.3f s after this end closed, exit status %s" % (gone, child.exit))
    return 0


# ---- the selftest's child --------------------------------------------------

# Enough of `bw serve` to be asked everything above. The password it takes
# is known to it by a digest, so that it is in nobody's arguments, and the
# session keys it hands out are made as it goes.
FAKE = r'''
import base64, hashlib, json, os, socket, sys
mode = os.environ.get("FAKE_MODE", "")
conn = socket.socket(fileno=3)
state = {"open": False}
names = ["selftest-name-Jt4", "selftest-name-Pb9", "selftest-name-Hd3"]
def reply(status, payload, raw=None):
    body = raw if raw is not None else json.dumps(payload).encode()
    extra = "Connection: close\r\n" if mode == "closes" else "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n"
    conn.sendall(("HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\n%s\r\n" % (status, len(body), extra)).encode() + body)
    if mode == "closes" or (mode == "drops" and state["open"]):
        sys.exit(0)
held = b""
while True:
    while b"\r\n\r\n" not in held:
        data = conn.recv(65536)
        if not data:
            if mode == "lingers":
                import time; time.sleep(60)
            sys.exit(0)
        held += data
    top, held = held.split(b"\r\n\r\n", 1)
    lines = top.decode().split("\r\n")
    method, path = lines[0].split(" ")[:2]
    headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:]}
    size = int(headers.get("content-length", "0"))
    while len(held) < size:
        held += conn.recv(65536)
    sent, held = held[:size], held[size:]
    if headers.get("host") != "localhost:8087":
        reply(403, None, b"Forbidden")
    elif (method, path) == ("GET", "/status"):
        reply(200, {"success": True, "data": {"object": "template", "template": {"serverUrl": None, "lastSync": "2026-10-01T08:15:30.123Z", "userEmail": "selftest-mail-Rv8", "userId": "selftest-id-0001", "status": "unlocked" if state["open"] else "locked"}}})
    elif (method, path) == ("POST", "/unlock"):
        given = json.loads(sent).get("password", "")
        if hashlib.sha256(given.encode()).hexdigest() == os.environ["FAKE_DIGEST"]:
            state["open"] = True
            key = "selftest-session-" + base64.b64encode(os.urandom(48)).decode()
            reply(200, {"success": True, "data": {"noColor": False, "object": "message", "title": "selftest-title-Lq6", "message": "export BW_" + "SESSION=\"%s\"" % key, "raw": key}})
        else:
            reply(400, {"success": False, "message": "Cryptography error, The decryption operation failed"})
    elif (method, path) == ("POST", "/lock"):
        state["open"] = False
        reply(200, {"success": True, "data": {"noColor": False, "object": "message", "title": "selftest-title-Lq6", "message": None}})
    elif (method, path) == ("GET", "/list/object/items"):
        if state["open"]:
            reply(200, {"success": True, "data": {"object": "list", "data": [{"object": "item", "type": 1, "name": n, "login": {"password": "selftest-secret-Wm5"}} for n in names]}})
        else:
            reply(400, {"success": False, "message": "Vault is locked."})
    else:
        reply(404, {"success": False, "message": "Not found."})
'''


def selftest():
    import hashlib
    invented = "selftest-password-Qx7"
    failed = []

    def tour(mode, waits=(0.05, 0.1), patience=0.6):
        env = {"PATH": "/usr/bin:/bin", "FAKE_MODE": mode,
               "FAKE_DIGEST": hashlib.sha256(invented.encode()).hexdigest()}
        say()
        say("==== the fake child, %s" % (mode or "as bw is hoped to be"))
        mark = len(LINES)
        spike([sys.executable, "-c", FAKE], env, lambda: invented, "the selftest's fake",
              waits=waits, patience=patience)
        return LINES[mark:]

    hoped = tour("")
    closing = tour("closes")
    dropping = tour("drops")
    lingering = tour("lingers")

    # The guard itself, on a line that never reaches the terminal as it is.
    before = WITHHELD[0]
    say("the guard is handed " + invented)
    if WITHHELD[0] != before + 1 or invented in LINES[-1]:
        failed.append("the guard let the password through")
    if before != 0:
        failed.append("%d lines of the run itself had a secret in them" % before)

    everything = "\n".join(LINES)
    for leaked in [invented, "selftest-session-", "selftest-name-", "selftest-secret-", "selftest-mail-",
                   "selftest-id-", "selftest-title-", "2026-10-01"] + SECRETS:
        if leaked in everything:
            failed.append("a value came through: %s" % leaked[:12])
    if len(SECRETS) < 8:
        failed.append("the run did not learn every session it was given (%d secrets known)" % len(SECRETS))

    def wants(lines, where, wanted):
        text = "\n".join(lines)
        for line in wanted:
            if line not in text:
                failed.append("not said, %s: %s" % (where, line))

    wants(hoped, "of a child that holds", [
        "BW_SESSION in the environment it is given: no",
        "a. run 3: spawn to the first /status",
        '"status": "locked"', '"userEmail": "string(17)"',
        "b. twenty requests in a row: 20 answered",
        "b. answers that said Connection: close so far: 0",
        "b. Keep-Alive headers it sent: ['timeout=5']",
        "g. POST /unlock with a wrong password: HTTP 400",
        "'Cryptography error, The decryption operation failed'",
        "g. GET /status with Host: localhost: HTTP 403, 9 bytes",
        "g. the connection after that refusal: still open",
        "c. run 1: the session key at data.raw is 81 characters",
        '"raw": "string(81)"', '"message": "string(',
        "d. run 3: the first list HTTP 200", "3 items",
        "d. run 3: finger to first row, less the finger: spawn to status",
        "c. ps eww from another process: the name BW_SESSION appears 0 times",
        "c. session 1 of this child: in ps eww 0 times, in its arguments 0, in kern.procargs2 0",
        "c. the master password: in ps eww 0 times, in its arguments 0, in kern.procargs2 0",
        "c. lsof: unix sockets 1, of them with a path (a socket file) 0, TCP sockets listening 0, paths under the run directory 0",
        "e. locked: lsof: unix sockets 1, of them with a path (a socket file) 0",
        "f. unlocked: the child exited by itself",
        "f. locked: the child exited by itself",
        "e. round 3: a list from the locked child: HTTP 400, 'Vault is locked.'",
        "e. round 3: POST /unlock on the same connection, the child not restarted: HTTP 200",
        "a session key of 81 characters, one not seen before",
        "e. what it holds in memory while locked cannot be seen from outside",
        "h. POST /lock HTTP 200",
        "b. after 0.05 s idle: HTTP 200", "b. after 0.1 s idle: HTTP 200",
        "b. answers that said Connection: close, over the whole life of this child: 0",
        "f. kept and locked: the child exited by itself",
        "h. locked: the last thing the vault was sent was POST /lock",
    ])
    wants(closing, "of a child that closes", [
        "a. run 3: spawn to the first /status",
        "b. THE CONNECTION DID NOT HOLD",
        "b. answers that said Connection: close so far: 1",
        "c. run 1: the unlock was not answered",
        "h. the vault was never opened by this run",
    ])
    wants(dropping, "of a child that goes once the vault is open", [
        "c. run 1: the session key at data.raw is 81 characters",
        "d. run 1: THE CONNECTION DID NOT HOLD after the unlock",
        "h. NOT LOCKED BY THIS RUN",
    ])
    wants(lingering, "of a child that will not go", [
        "f. unlocked: THE CHILD WAS STILL RUNNING",
        "f. locked: THE CHILD WAS STILL RUNNING",
        "f. kept and locked: THE CHILD WAS STILL RUNNING",
        "h. locked: the last thing the vault was sent was POST /lock",
    ])
    leftover = run(["/usr/bin/pgrep", "-f", "FAKE_DIGEST|selftest-name-Jt4"]) or b""
    if leftover.strip():
        failed.append("a fake child was left running")

    # The same search again: what was said about the failures is printed too.
    for line in failed:
        print("selftest: FAILED, " + line)
    if not failed:
        print("selftest: ok")
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if sys.argv[1:]:
        print("scripts/spike-fd.py takes --selftest or nothing")
        return 2
    if not os.access(BW, os.X_OK):
        print("no bw at %s" % BW)
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
    version = run([BW, "--version"])
    say("bw %s, macOS %s" % ((version or b"?").decode().strip()[:20],
                             (run(["/usr/bin/sw_vers", "-productVersion"]) or b"?").decode().strip()))
    status = spike([BW, "serve", "--hostname", "fd+connected://%d" % FD], env,
                   lambda: getpass.getpass("Master password (not shown, not stored): "),
                   "bw serve --hostname fd+connected://%d" % FD)
    if WITHHELD[0]:
        status = 1
        say("%d lines were withheld because a secret was in them: that is a fault in this script, say so" % WITHHELD[0])
    say()
    say("Report written to docs/spikes/fd-run.txt. You are not asked to read it: tell the session it is there.")
    return status


if __name__ == "__main__":
    sys.exit(main())

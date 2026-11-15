#!/usr/bin/env python3
"""OP-18: what `bw login` says, without an account and without the network.

The real `bw` is pointed at a server that is this script, listening on
127.0.0.1, and is run once for each way a login can go wrong. Its state goes
in a temporary directory, so the app's own login and the user's are never read.
The server refuses every login: it has no account to give, and a login that
works needs keys only Bitwarden's server can make.

What is measured is the CLI: its sentence, its exit code, where it prints,
and whether it will take an answer on standard input when it has no terminal.
What is not measured is the server. The bodies below are what Bitwarden's
identity server is read to answer, written from the CLI's own parsing of
them, and the real server may say more.

    scripts/spike-login.py            every case, one block each
"""

import http.server
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

BW = "/opt/homebrew/bin/bw"
PASSWORD = "spike-password-not-a-real-one"
SEEN = []


def refusal(email, form):
    """The identity server's answer to a token request, chosen by the email."""
    who = email.split("@")[0]
    code = form.get("twoFactorToken", [None])[0]
    otp = form.get("newDeviceOtp", [None])[0]
    if code is not None:
        return {"error": "invalid_grant",
                "error_description": "invalid_username_or_password",
                "ErrorModel": {"Message": "Two-step token is invalid. Try again.", "Object": "error"}}
    if otp is not None:
        return {"error": "invalid_grant",
                "error_description": "invalid_username_or_password",
                "ErrorModel": {"Message": "invalid new device otp", "Object": "error"}}
    if who == "authenticator":
        return {"error": "invalid_grant", "error_description": "Two factor required.",
                "TwoFactorProviders": ["0"], "TwoFactorProviders2": {"0": None}}
    if who == "emailed":
        return {"error": "invalid_grant", "error_description": "Two factor required.",
                "TwoFactorProviders": ["1"],
                "TwoFactorProviders2": {"1": {"Email": "e***@example.invalid"}}}
    if who == "both":
        return {"error": "invalid_grant", "error_description": "Two factor required.",
                "TwoFactorProviders": ["0", "1"],
                "TwoFactorProviders2": {"0": None, "1": {"Email": "b***@example.invalid"}}}
    if who == "keyonly":
        return {"error": "invalid_grant", "error_description": "Two factor required.",
                "TwoFactorProviders": ["7"], "TwoFactorProviders2": {"7": {}}}
    if who == "device":
        return {"error": "invalid_grant",
                "error_description": "invalid_username_or_password",
                "ErrorModel": {"Message": "new device verification required", "Object": "error"}}
    return {"error": "invalid_grant",
            "error_description": "invalid_username_or_password",
            "ErrorModel": {"Message": "Username or password is incorrect. Try again.", "Object": "error"}}


class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        SEEN.append("GET " + self.path)
        self.answer(404, {"message": "not here"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        path = self.path.split("?")[0]
        if "prelogin" in path:
            SEEN.append("POST " + path)
            self.answer(200, {"kdf": 0, "kdfIterations": 600000,
                              "kdfMemory": None, "kdfParallelism": None,
                              "kdfSettings": {"kdfType": 0, "iterations": 600000},
                              "salt": json.loads(body or "{}").get("email", "")})
        elif path.endswith("/connect/token"):
            form = urllib.parse.parse_qs(body)
            keys = sorted(k for k in form if k in (
                "grant_type", "twoFactorToken", "twoFactorProvider", "newDeviceOtp", "client_secret"))
            SEEN.append("POST " + path + " " + ",".join(keys))
            if form.get("grant_type", [""])[0] == "client_credentials":
                self.answer(400, {"error": "invalid_client"})
            else:
                self.answer(400, refusal(form.get("username", [""])[0], form))
        elif "two-factor/send-email-login" in path:
            SEEN.append("POST " + path)
            self.answer(200, {})
        else:
            SEEN.append("POST " + path)
            self.answer(404, {"message": "not here"})


def run(title, args, env=None, stdin=None):
    """One `bw`, with a state directory of its own already pointed at us."""
    del SEEN[:]
    full = dict(BASE)
    full.update(env or {})
    try:
        done = subprocess.run([BW] + args, env=full, input=stdin, capture_output=True,
                              text=True, timeout=60,
                              stdin=None if stdin is not None else subprocess.DEVNULL)
        code, out, err = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as late:
        code, out, err = "timeout", (late.stdout or b"").decode(), (late.stderr or b"").decode()
    print("\n## " + title)
    print("args:   " + " ".join(args))
    print("exit:   " + str(code))
    print("stdout: " + repr(out[:400]))
    print("stderr: " + repr(err[:400]))
    print("asked:  " + "; ".join(s for s in SEEN if not s.startswith("GET ")))


def wrapper():
    """The shell `LoginChild` puts between the app and `bw`, read out of
    its source so that what is measured here is what the app runs."""
    here = os.path.dirname(os.path.abspath(__file__))
    source = open(os.path.join(here, "..", "Sources", "Bw", "LoginChild.swift")).read()
    body = source.split('private static let script = """\n', 1)[1].split('\n    """', 1)[0]
    return "\n".join(line[4:] for line in body.split("\n")).replace("\\\\", "\\")


def wrapped(title, who, state, answer):
    """One login as the app starts it: `bw` free to ask, behind the shell,
    its answers down a pipe. `answer` is sent when it asks, or the pipe is
    closed on it when `answer` is None."""
    del SEEN[:]
    env = dict(BASE, OP_PW=PASSWORD)
    child = subprocess.Popen(
        ["/bin/sh", "-c", wrapper(), "sh", BW, os.path.join(state, "login.pid"),
         os.path.join(state, "login.answers"),
         "login", who + "@example.invalid", "--passwordenv", "OP_PW", "--response"],
        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    heard = b""
    os.set_blocking(child.stderr.fileno(), False)
    started = time.time()
    while b"code:" not in heard and b"login email:" not in heard and time.time() - started < 30:
        heard += child.stderr.read() or b""
        time.sleep(0.05)
    asked = time.time()
    pid = int(open(os.path.join(state, "login.pid")).read())
    if answer is None:
        child.stdin.close()
    else:
        child.stdin.write(answer.encode() + b"\n")
        child.stdin.flush()
    try:
        code = child.wait(timeout=20)
    except subprocess.TimeoutExpired:
        code = "timeout"
        child.kill()
    took = time.time() - asked
    time.sleep(0.2)
    try:
        os.kill(pid, 0)
        alive = "still running"
    except OSError:
        alive = "gone"
    print("\n## " + title)
    print("asked after: %.2f s" % (asked - started))
    print("exit:   %s, %.2f s after the answer; bw is %s" % (code, took, alive))
    print("stdout: " + repr(child.stdout.read().decode()[:300]))
    print("asked:  " + "; ".join(s for s in SEEN if not s.startswith("GET ")))
    print("left:   " + ", ".join(sorted(f for f in os.listdir(state) if f.startswith("login."))))


def plain(state, here):
    """A second state directory, pointed at the same port without TLS."""
    other = os.path.join(state, "plain")
    os.mkdir(other)
    subprocess.run([BW, "config", "server", here.replace("https:", "http:")],
                   env=dict(BASE, BITWARDENCLI_APPDATA_DIR=other), capture_output=True)
    return other


def main():
    global BASE
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
    state = tempfile.mkdtemp(prefix="oripass-spike-login-")
    # The CLI refuses a server that is not HTTPS, so the server gets a
    # certificate made here and node is told to trust it for this run only.
    cert, key = os.path.join(state, "cert.pem"), os.path.join(state, "key.pem")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1",
                    "-addext", "subjectAltName=IP:127.0.0.1"],
                   check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    here = "https://127.0.0.1:%d" % server.server_address[1]
    BASE = {"BITWARDENCLI_APPDATA_DIR": state, "HOME": state, "PATH": "/usr/bin:/bin",
            "NO_COLOR": "1", "NODE_EXTRA_CA_CERTS": cert}
    quiet = {"BW_NOINTERACTION": "true", "OP_PW": PASSWORD}
    talk = {"OP_PW": PASSWORD}
    try:
        run("config server", ["config", "server", here, "--response"], quiet)
        run("status", ["status"], quiet)
        run("a server that is not HTTPS, at login",
            ["login", "wrong@example.invalid", "--passwordenv", "OP_PW", "--response"],
            dict(quiet, BITWARDENCLI_APPDATA_DIR=plain(state, here)))
        run("no password", ["login", "wrong@example.invalid", "--passwordenv", "OP_PW", "--response"],
            {"BW_NOINTERACTION": "true"})
        run("an email that is not one", ["login", "nobody", "--passwordenv", "OP_PW", "--response"], quiet)
        run("wrong password", ["login", "wrong@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("wrong password, plain", ["login", "wrong@example.invalid", "--passwordenv", "OP_PW"], quiet)
        run("second step, one method, asked of nobody",
            ["login", "authenticator@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("second step, emailed, asked of nobody",
            ["login", "emailed@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("second step, two methods, asked of nobody",
            ["login", "both@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("second step, two methods, one named",
            ["login", "both@example.invalid", "--passwordenv", "OP_PW", "--method", "1", "--response"], quiet)
        run("second step, a method the CLI cannot do",
            ["login", "keyonly@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("second step, a method that is no method",
            ["login", "both@example.invalid", "--passwordenv", "OP_PW", "--method", "42", "--response"], quiet)
        run("new device, asked of nobody",
            ["login", "device@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
        run("second step, code on standard input, no terminal",
            ["login", "authenticator@example.invalid", "--passwordenv", "OP_PW", "--response"],
            talk, stdin="000000\n")
        run("second step, two methods, method named, code on standard input",
            ["login", "both@example.invalid", "--passwordenv", "OP_PW", "--method", "0", "--response"],
            talk, stdin="000000\n")
        run("second step, two methods, nothing named, standard input closed",
            ["login", "both@example.invalid", "--passwordenv", "OP_PW", "--response"], talk, stdin="")
        run("new device, code on standard input, no terminal",
            ["login", "device@example.invalid", "--passwordenv", "OP_PW", "--response"],
            talk, stdin="000000\n")
        run("new device, standard input closed",
            ["login", "device@example.invalid", "--passwordenv", "OP_PW", "--response"], talk, stdin="")
        wrapped("behind the app's shell: second step, code sent when asked", "authenticator", state, "000000")
        wrapped("behind the app's shell: new device, code sent when asked", "device", state, "000000")
        wrapped("behind the app's shell: the pipe closed on its question", "authenticator", state, None)
        run("API key, none given", ["login", "--apikey", "--response"], {"BW_NOINTERACTION": "true"})
        run("API key, wrong",
            ["login", "--apikey", "--response"],
            {"BW_NOINTERACTION": "true", "BW_CLIENTID": "user.spike", "BW_CLIENTSECRET": "spike"})
        run("API key, an organisation's",
            ["login", "--apikey", "--response"],
            {"BW_NOINTERACTION": "true", "BW_CLIENTID": "organization.spike", "BW_CLIENTSECRET": "spike"})
        run("the default server, by its name", ["config", "server", "https://bitwarden.com", "--response"], quiet)
        run("status after that", ["status"], quiet)
        run("back to this one", ["config", "server", here, "--response"], quiet)
        server.shutdown()
        server.server_close()
        run("a server that does not answer",
            ["login", "wrong@example.invalid", "--passwordenv", "OP_PW", "--response"], quiet)
    finally:
        shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

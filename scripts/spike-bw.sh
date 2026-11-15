#!/bin/bash
# OP-2: what `bw` does on this Mac, on a real account, by hand.
#
# Read this before running it. It asks for the master password with `read -s`
# and hands it to curl on standard input, never as an argument. Everything it
# prints goes through `shape`, which keeps keys, types, counts and timings and
# drops every value: a string becomes "string(n)" with its length, except the
# handful of state words listed in KEEP below and the CLI's own sentences when
# it refuses. The sentence a good unlock answers with is not kept, because it
# has the session key in it. Nothing is written but the report, which is the
# same text as the terminal shows.
#
#   1. brew install bitwarden-cli
#   2. export BITWARDENCLI_APPDATA_DIR="$HOME/Library/Application Support/OriPass/bw"
#      bw login                       (in Terminal.app, typed into bw itself)
#   3. scripts/spike-bw.sh            (reads only)
#      scripts/spike-bw.sh --writes   (also makes one item named "OriPass spike",
#                                      archives it, brings it back and deletes
#                                      it for good, to learn how the archive works;
#                                      then one login named "OriPass spike login",
#                                      whose password it changes twice and which it
#                                      writes once from an old copy, to learn who
#                                      keeps the history and what an old copy is
#                                      answered with, and deletes that for good too.
#                                      It then looks for both by name, in the vault
#                                      and in the trash, and says LEFT BEHIND if
#                                      either is still there)
#
# `scripts/spike-bw.sh --selftest` needs no `bw` and no account. It feeds
# `shape` and `history` bodies made up in this file and fails if one made-up
# value comes out the other side.
#
# The last step locks the CLI for real, and so does the exit trap if the run
# stops early, so the session this run made is dead when it ends.
#
# The app itself makes no socket file since OP-65: its child serves one
# connected socket. This script still does, because curl cannot be handed a
# socketpair. For as long as it runs, a `bw` with the vault open answers on
# a socket file under the app's run directory to any program running as
# you, with no password. The file is removed on every way out.

set -u
export BITWARDENCLI_APPDATA_DIR="$HOME/Library/Application Support/OriPass/bw"
export BW_NOINTERACTION=true
BW=/opt/homebrew/bin/bw
RUN="$HOME/Library/Application Support/OriPass/run"
SOCK="$RUN/spike.sock"
REPORT="$(cd "$(dirname "$0")/.." && pwd)/docs/spikes/bw-run.txt"
WRITES=0; [ "${1:-}" = "--writes" ] && WRITES=1
CHILD=

now() { python3 -c 'import time; print(time.time())'; }
since() { python3 -c "import time; print(round(time.time() - $1, 3))"; }
say() { printf '\n## %s\n' "$*"; }

# Keys, types and lengths. Values never.
shape() {
python3 -c '
import json, sys
KEEP = {"status": {"unauthenticated", "locked", "unlocked"}, "object": None, "success": None}
# Every key any member of a list has, at every depth. The first run kept the
# first member that had a key and so never showed what is under a list that
# was empty in that one, which a passkey was.
def join(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) == {"array", "of"} == set(b):
            inner = join(a["of"], b["of"]) if a["of"] and b["of"] else a["of"] or b["of"]
            return {"array": max(a["array"], b["array"]), "of": inner}
        return {k: join(a[k], b[k]) if k in a and k in b else a.get(k, b.get(k)) for k in list(a) + [k for k in b if k not in a]}
    if isinstance(a, list) and isinstance(b, list):
        return sorted(set(a) | set(b))
    return b if a is None else a
def shape(v, key=None):
    if isinstance(v, dict):
        return {k: shape(x, k) for k, x in v.items()}
    if isinstance(v, list):
        merged = {}
        scalars = set()
        for x in v:
            s = shape(x, key)
            if isinstance(s, dict):
                merged = join(merged, s)
            else:
                scalars.add(json.dumps(s))
        inner = merged if merged else sorted(scalars)
        return {"array": len(v), "of": inner}
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, (int, float)):
        return "number"
    if key in KEEP and (KEEP[key] is None or v in KEEP[key]):
        return v
    # The sentence of a refusal is kept. The answer to a good unlock is not: its
    # message quotes the session key three times, as lines to paste in a shell.
    # (No apostrophes in here: this python sits inside single quotes.)
    if key == "message" and "BW_SESSION" not in v:
        return v
    return "string(%d)" % len(v)
raw = sys.stdin.read()
try:
    print(json.dumps(shape(json.loads(raw)), indent=1, sort_keys=True))
except ValueError:
    print("not JSON, %d bytes" % len(raw))
'
}

# What an item's passwordHistory holds, values never: how many entries, their
# keys, and for each password this run itself set, how often it is there and
# where first. The passwords come in the environment, one to a line, and the
# item's object on standard input, bare or inside the envelope.
history() {
python3 -c '
import json, os, sys
try:
    item = json.load(sys.stdin)
except ValueError:
    print("  passwordHistory: the answer was not JSON"); sys.exit()
item = item.get("data", item) if isinstance(item, dict) else {}
held = item.get("passwordHistory")
if held is None:
    print("  passwordHistory: null" if "passwordHistory" in item else "  passwordHistory: no such key"); sys.exit()
passwords = [e.get("password") for e in held if isinstance(e, dict)]
print("  passwordHistory: %d entries, keys %s" % (len(held), sorted({k for e in held if isinstance(e, dict) for k in e})))
for n, mine in enumerate(os.environ.get("SET_HERE", "").splitlines(), 1):
    print("  password %d of this run: there %d times, first at %s" % (n, passwords.count(mine), passwords.index(mine) if mine in passwords else None))
print("  entries that are none of them: %d" % sum(1 for p in passwords if p not in os.environ.get("SET_HERE", "").splitlines()))
print("  the password it has now is number: %s" % next((n for n, mine in enumerate(os.environ.get("SET_HERE", "").splitlines(), 1) if (item.get("login") or {}).get("password") == mine), None))
'
}

# What became of an item this run made and deleted: the body of a GET for it
# on standard input. Gone, in the trash, or still in the vault.
fate() {
python3 -c '
import json, sys
try:
    answer = json.load(sys.stdin)
except ValueError:
    print("not JSON"); sys.exit()
if answer.get("success") is not True:
    print("gone (%s)" % answer.get("message"))
elif (answer.get("data") or {}).get("deletedDate"):
    print("STILL THERE, in the trash")
else:
    print("STILL THERE, in the vault")
'
}

# How many items carry one of this script's own names: the list and the trash
# on standard input, a line each. Those are the only names it ever compares,
# and it prints the two counts and no name it found.
left() {
python3 -c '
import json, sys
vault, trash = [[i for i in json.loads(l)["data"]["data"] if (i.get("name") or "").startswith("OriPass spike")] for l in sys.stdin.read().splitlines()[:2]]
print("items named OriPass spike: %d in the vault, %d in the trash" % (len(vault), len(trash)))
if vault or trash:
    print("LEFT BEHIND: this script made %d item(s) it did not manage to delete. Delete them by hand in the web vault, and empty them out of its trash." % (len(vault) + len(trash)))
'
}

if [ "${1:-}" = "--selftest" ]; then
    # Every value below is made up here, and none of them may be printed.
    A="selftest-old-Zq7"; B="selftest-new-Xk2"; C="selftest-other-Wm5"
    BODY=$(A="$A" B="$B" C="$C" python3 -c 'import json, os
e = os.environ
print(json.dumps({"success": True, "data": {"object": "item", "id": "selftest-id-0001", "name": "selftest name Jt4",
    "revisionDate": "2026-10-09T10:00:00.000Z", "login": {"username": "selftest-user-Pb9", "password": e["B"], "totp": None},
    "passwordHistory": [{"password": e["A"], "lastUsedDate": "2026-10-09T10:00:00.000Z"},
                        {"password": e["C"], "lastUsedDate": "2026-10-08T10:00:00.000Z"},
                        {"password": e["A"], "lastUsedDate": "2026-10-07T10:00:00.000Z"}]}}))')
    OUT=$(echo "$BODY" | shape; echo "$BODY" | SET_HERE="$A
$B" history
        echo '{"success":false,"message":"The cipher you are updating is out of date."}' | shape
        echo '{"data":{"passwordHistory":null}}' | SET_HERE="$A" history
        echo '{"data":{"login":{}}}' | SET_HERE="$A" history
        echo 'not json at all' | history
        echo '{"success":false,"message":"Not found."}' | fate
        echo '{"success":true,"data":{"id":"selftest-id-0001","name":"selftest name Jt4","deletedDate":"2026-10-09T10:00:00.000Z"}}' | fate
        echo '{"success":true,"data":{"id":"selftest-id-0001","name":"selftest name Jt4"}}' | fate
        printf '%s\n%s\n' '{"data":{"data":[{"name":"selftest name Jt4"},{"name":"OriPass spike login"},{"name":null}]}}' '{"data":{"data":[{"name":"OriPass spike 2"}]}}' | left
        printf '%s\n%s\n' '{"data":{"data":[{"name":"selftest name Jt4"}]}}' '{"data":{"data":[]}}' | left
        echo '[{"login":{"fido2Credentials":[],"uris":[{"uri":"selftest-uri-Hd3"}]}},{"login":{"totp":"selftest-totp-Rv8","fido2Credentials":[{"rpId":"selftest-rp-Lq6","counter":"0"}],"uris":[{"uri":"selftest-uri-Hd3","match":1}]}}]' | shape)
    echo "$OUT"
    FAILED=0
    for leaked in "$A" "$B" "$C" selftest-id-0001 "selftest name Jt4" selftest-user-Pb9 2026-10-0 \
                  selftest-uri-Hd3 selftest-totp-Rv8 selftest-rp-Lq6; do
        case "$OUT" in *"$leaked"*) echo "selftest: FAILED, a value came through: $leaked"; FAILED=1;; esac
    done
    for wanted in "passwordHistory: 3 entries, keys ['lastUsedDate', 'password']" \
                  "password 1 of this run: there 2 times, first at 0" \
                  "password 2 of this run: there 0 times, first at None" \
                  "entries that are none of them: 1" \
                  "the password it has now is number: 2" \
                  "The cipher you are updating is out of date." \
                  "passwordHistory: null" "passwordHistory: no such key" "the answer was not JSON" \
                  "gone (Not found.)" "STILL THERE, in the trash" "STILL THERE, in the vault" \
                  "items named OriPass spike: 1 in the vault, 1 in the trash" "LEFT BEHIND: this script made 2 item(s)" \
                  "items named OriPass spike: 0 in the vault, 0 in the trash" \
                  '"password": "string(16)"' '"rpId": "string(15)"' '"counter": "string(1)"' \
                  '"match": "number"' '"totp": "string(17)"'; do
        case "$OUT" in *"$wanted"*) ;; *) echo "selftest: FAILED, not said: $wanted"; FAILED=1;; esac
    done
    [ "$FAILED" = 0 ] && echo "selftest: ok"
    exit "$FAILED"
fi

mkdir -p "$RUN" && chmod 700 "$RUN"
exec > >(tee "$REPORT") 2>&1

# call METHOD PATH: the body, with the HTTP status on a last line of its own.
call() {
    curl -s --max-time 120 --unix-socket "$SOCK" -X "$1" -w '\n%{http_code}' \
        -H 'Content-Type: application/json' ${3:+--data-binary @-} "http://localhost:8087$2"
}
body() { sed '$d'; }
code() { tail -n 1; }

start() { # start [session]; prints seconds to the first /status
    rm -f "$SOCK"
    local t; t=$(now)
    if [ -n "${1:-}" ]; then
        BW_SESSION="$1" "$BW" serve --hostname "unix://$SOCK" >/dev/null 2>"$RUN/spike.err" &
    else
        "$BW" serve --hostname "unix://$SOCK" >/dev/null 2>"$RUN/spike.err" &
    fi
    CHILD=$!
    for _ in $(seq 1 400); do
        curl -s --max-time 2 --unix-socket "$SOCK" http://localhost:8087/status >/dev/null 2>&1 && break
        kill -0 "$CHILD" 2>/dev/null || { echo "child exited: $(cat "$RUN/spike.err")"; return 1; }
        sleep 0.025
    done
    echo "start to first /status: $(since "$t") s"
}
stop() { [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=; rm -f "$SOCK"; }
# However the run ends, a session it made does not outlive it.
trap 'stop; [ -n "${SESSION:-}" ] && BW_SESSION="$SESSION" "$BW" lock >/dev/null 2>&1; rm -f "$RUN/spike.err"' EXIT

timed() { # timed LABEL METHOD PATH
    local t; t=$(now)
    local c; c=$(call "$2" "$3" | code)
    echo "$1: $(since "$t") s, HTTP $c"
}

say "versions"
"$BW" --version
sw_vers -productVersion
/usr/bin/codesign -dv /opt/homebrew/opt/node/bin/node 2>&1 | grep -E 'flags|Signature'

say "bw status, one-shot, three runs"
for _ in 1 2 3; do t=$(now); "$BW" status | shape; echo "took $(since "$t") s"; done

say "child with no session"
start || exit 1
call GET /status | body | shape
echo "socket path is ${#SOCK} bytes; $(stat -f '%Sp' "$RUN") on its directory, $(stat -f '%Sp' "$SOCK") on the socket"

say "a locked child refuses"
r=$(call GET /list/object/items); echo "HTTP $(echo "$r" | code)"; echo "$r" | body | shape

say "origin protection on a socket file"
for h in "Host: localhost:8087" "Host: 127.0.0.1:8087" "Host: localhost" "Host: evil.example" "Host:"; do
    echo "$h -> HTTP $(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "$h" http://localhost:8087/status)"
done
echo "with an Origin header -> HTTP $(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H 'Origin: https://evil.example' http://localhost:8087/status)"

say "unlock, wrong password"
r=$(printf '{"password":"not-the-password-%s"}' "$RANDOM" | call POST /unlock body)
echo "HTTP $(echo "$r" | code)"; echo "$r" | body | shape

say "unlock"
printf 'Master password (not shown, not stored): ' >/dev/tty
IFS= read -rs PW </dev/tty; printf '\n' >/dev/tty
t=$(now)
r=$(printf '%s' "$PW" | python3 -c 'import json,sys; sys.stdout.write(json.dumps({"password": sys.stdin.read()}))' | call POST /unlock body)
unset PW
echo "took $(since "$t") s, HTTP $(echo "$r" | code)"
echo "$r" | body | shape
SESSION=$(echo "$r" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["raw"])' 2>/dev/null)
[ -n "$SESSION" ] || { echo "no session at data.raw; stopping"; exit 1; }
echo "session key is ${#SESSION} characters"
call GET /status | body | shape

say "lists, timed"
timed "first /list/object/items" GET /list/object/items
timed "second /list/object/items" GET /list/object/items
timed "/list/object/folders" GET /list/object/folders
for _ in 1 2 3; do timed "/sync" POST /sync; done

say "who else can ask"
echo "ps eww shows BW_SESSION for this child: n/a, this child has none in its environment"
lsof -a -p "$CHILD" -U 2>/dev/null | awk 'NR>1 {print $5, $NF}' | sed "s|$HOME|~|"
echo "TCP listeners: $(lsof -a -p "$CHILD" -iTCP -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')"

say "counts"
ITEMS=$(call GET /list/object/items | body)
TRASH=$(call GET '/list/object/items?trash=true' | body)
FOLDERS=$(call GET /list/object/folders | body)
COLLECTIONS=$(call GET /list/object/collections | body)
printf '%s\n%s\n%s\n%s\n' "$ITEMS" "$TRASH" "$FOLDERS" "$COLLECTIONS" | python3 -c '
import json, sys, re
from collections import Counter
items, trash, folders, collections = [json.loads(l)["data"]["data"] for l in sys.stdin.read().splitlines()[:4]]
print("items:", len(items), " trash:", len(trash), " folders:", len(folders), " collections:", len(collections))
print("by type:", dict(sorted(Counter(i["type"] for i in items).items())))
sizes = sorted(Counter(i.get("folderId") for i in items if i.get("folderId")).values(), reverse=True)
print("in no folder:", sum(1 for i in items if not i.get("folderId")), " per folder, largest first:", sizes)
has = lambda f: sum(1 for i in items if f(i))
login = lambda i: i.get("login") or {}
print("archived:", has(lambda i: i.get("archivedDate")))
print("with totp:", has(lambda i: login(i).get("totp")))
print("with attachments:", has(lambda i: i.get("attachments")))
print("with a passkey:", has(lambda i: login(i).get("fido2Credentials")))
print("with reprompt:", has(lambda i: i.get("reprompt")))
print("in an organisation:", has(lambda i: i.get("organizationId")))
print("favourites:", has(lambda i: i.get("favorite")))
print("with custom fields:", has(lambda i: i.get("fields")), " field types:", dict(Counter(f.get("type") for i in items for f in i.get("fields") or [])))
print("uri match values:", dict(Counter(str(u.get("match")) for i in items for u in login(i).get("uris") or [])))
print("with password history:", has(lambda i: i.get("passwordHistory")))
frac = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z$"); plain = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
dates = [i.get(k) for i in items for k in ("revisionDate", "creationDate") if i.get(k)]
print("dates with fractional seconds:", sum(1 for d in dates if frac.match(d)), " without:", sum(1 for d in dates if plain.match(d)), " other:", sum(1 for d in dates if not frac.match(d) and not plain.match(d)))
totp = [login(i)["totp"] for i in items if login(i).get("totp")]
print("totp forms: otpauth", sum(1 for t in totp if t.startswith("otpauth://")), " steam", sum(1 for t in totp if t.startswith("steam://")), " bare", sum(1 for t in totp if "://" not in t))
'

say "the shape of an item, every key seen, by type"
for t in 1 2 3 4 5; do
    echo "type $t:"
    echo "$ITEMS" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']['data']
print(json.dumps([i for i in d if i['type'] == $t]))" | shape
done
echo "types this script does not know: $(echo "$ITEMS" | python3 -c 'import json,sys; print(sorted({i["type"] for i in json.load(sys.stdin)["data"]["data"]} - {1,2,3,4,5}))')"
echo "the list envelope:"; echo "$ITEMS" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["data"]["data"]=d["data"]["data"][:0]; print(json.dumps(d))' | shape
echo "a folder:"; echo "$FOLDERS" | shape
echo "collections:"; echo "$COLLECTIONS" | shape
echo "sync:"; call POST /sync | body | shape
echo "a trashed item's extra keys:"; echo "$TRASH" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["data"]; print(json.dumps([{k: i[k] for k in ("deletedDate",) if k in i} for i in d][:1]))' | shape

say "one-time codes and Premium"
TOTP_ID=$(echo "$ITEMS" | python3 -c 'import json,sys; print(next((i["id"] for i in json.load(sys.stdin)["data"]["data"] if (i.get("login") or {}).get("totp")), ""))')
if [ -n "$TOTP_ID" ]; then
    r=$(call GET "/object/totp/$TOTP_ID"); echo "HTTP $(echo "$r" | code)"; echo "$r" | body | shape
else
    echo "no item has a totp"
fi

say "generate"
for q in "" "?length=24&uppercase=true&lowercase=true&number=true&special=true" \
         "?passphrase=true&words=4&separator=-&capitalize=true&includeNumber=true" "?length=6&number=true" "?length=6&number=true&uppercase=false&lowercase=false"; do
    r=$(call GET "/generate$q")
    echo "/generate$q -> HTTP $(echo "$r" | code)"
    echo "$r" | body | shape
    echo "$r" | body | python3 -c '
import json, sys, re
try: p = json.load(sys.stdin)["data"]["data"]
except Exception: sys.exit()
print("  classes:", "".join(c for c, rx in (("U", "[A-Z]"), ("l", "[a-z]"), ("9", "[0-9]"), ("#", "[^A-Za-z0-9]")) if re.search(rx, p)))'
done

say "templates"
for t in item item.login item.card item.identity item.securenote item.sshkey item.field item.login.uri folder; do
    r=$(call GET "/object/template/$t"); echo "$t: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
done

# swept ID: whether an item deleted for good is gone, asked three ways, each
# only if the one before it still found the item: as it stands, after a sync,
# and after the trash and then for good, which is the order that was seen to
# work.
swept() {
    local r
    r=$(call GET "/object/item/$1"); echo "afterwards: HTTP $(echo "$r" | code), $(echo "$r" | body | fate)"
    case "$(echo "$r" | body | fate)" in gone*) return;; esac
    call POST /sync >/dev/null
    r=$(call GET "/object/item/$1"); echo "after a sync: HTTP $(echo "$r" | code), $(echo "$r" | body | fate)"
    case "$(echo "$r" | body | fate)" in gone*) return;; esac
    r=$(call DELETE "/object/item/$1"); echo "to the trash: HTTP $(echo "$r" | code)"
    r=$(call DELETE "/object/item/$1?permanent=true"); echo "and for good from there: HTTP $(echo "$r" | code)"
    call POST /sync >/dev/null
    r=$(call GET "/object/item/$1"); echo "after that and a sync: HTTP $(echo "$r" | code), $(echo "$r" | body | fate)"
    case "$(echo "$r" | body | fate)" in gone*) return;; esac
    echo "LEFT BEHIND: an item this script made would not be deleted. Look for \"OriPass spike\" in the web vault and its trash."
}

if [ "$WRITES" = 1 ]; then
    say "what earlier runs left"
    (call GET /list/object/items | body; call GET '/list/object/items?trash=true' | body) | left

    say "the archive, on an item made for it"
    r=$(call GET /object/template/item | body | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"]["template"]
t.update(name="OriPass spike", type=2, notes=None, secureNote={"type": 0}, login=None, card=None, identity=None)
print(json.dumps(t))' | call POST /object/item body)
    echo "create: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
    SPIKE=$(echo "$r" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)
    if [ -n "$SPIKE" ]; then
        r=$(call POST "/archive/item/$SPIKE"); echo "archive: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        r=$(call GET "/object/item/$SPIKE"); echo "after archive, archivedDate set: $(echo "$r" | body | python3 -c 'import json,sys; print(bool(json.load(sys.stdin)["data"].get("archivedDate")))')"
        r=$(call POST "/restore/item/$SPIKE"); echo "restore on an archived item: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        r=$(call GET "/object/item/$SPIKE" | body | python3 -c '
import json, sys
i = json.load(sys.stdin)["data"]; i["name"] = "OriPass spike 2"; print(json.dumps(i))' | call PUT "/object/item/$SPIKE" body)
        echo "edit: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        r=$(call DELETE "/object/item/$SPIKE"); echo "delete: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        r=$(call POST "/restore/item/$SPIKE"); echo "restore from the trash: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        # For good from the trash, which is the only place the app asks it
        # from. The run of 2026-10-11 asked it of an item it had just
        # restored, so this was never seen.
        r=$(call DELETE "/object/item/$SPIKE"); echo "delete again: HTTP $(echo "$r" | code)"
        r=$(call DELETE "/object/item/$SPIKE?permanent=true"); echo "delete for good, from the trash: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        swept "$SPIKE"
    fi

    # OP-37's second box and its fourth: which side keeps the old password, and
    # what a write from an old copy is answered with. The three passwords are
    # made here and are nobody's.
    say "a password changed, and an old copy sent, on a login made for it"
    P1="spike-one-$RANDOM$RANDOM"; P2="spike-two-$RANDOM$RANDOM"; P3="spike-three-$RANDOM$RANDOM"
    SET_HERE="$P1
$P2
$P3"
    export SET_HERE
    LOGIN=$(call GET /object/template/item.login | body)
    r=$( (call GET /object/template/item | body; echo "$LOGIN") | P="$P1" python3 -c '
import json, os, sys
item, login = [json.loads(l)["data"]["template"] for l in sys.stdin.read().splitlines()[:2]]
login = {k: ([] if isinstance(v, list) else None) for k, v in login.items()}
login["password"] = os.environ["P"]
item.update(name="OriPass spike login", type=1, notes=None, login=login, secureNote=None, card=None, identity=None, fields=[])
print(json.dumps(item))' | call POST /object/item body)
    echo "create: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
    SPIKE=$(echo "$r" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)
    if [ -n "$SPIKE" ]; then
        FIRST=$(call GET "/object/item/$SPIKE" | body)
        echo "as made:"; echo "$FIRST" | history

        r=$(echo "$FIRST" | P="$P2" python3 -c '
import json, os, sys
i = json.load(sys.stdin)["data"]; i["login"]["password"] = os.environ["P"]; print(json.dumps(i))' | call PUT "/object/item/$SPIKE" body)
        echo "PUT with the password changed and the history as it came: HTTP $(echo "$r" | code)"
        echo "the answer:"; echo "$r" | body | history
        SECOND=$(call GET "/object/item/$SPIKE" | body)
        echo "read again:"; echo "$SECOND" | history

        r=$(echo "$SECOND" | P="$P3" OLD="$P2" python3 -c '
import json, os, sys, time
i = json.load(sys.stdin)["data"]; i["login"]["password"] = os.environ["P"]
used = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
i["passwordHistory"] = ([{"password": os.environ["OLD"], "lastUsedDate": used}] + (i.get("passwordHistory") or []))[:5]
print(json.dumps(i))' | call PUT "/object/item/$SPIKE" body)
        echo "PUT with the password changed and the old one sent first in the history, as the app sends it: HTTP $(echo "$r" | code)"
        echo "read again:"; call GET "/object/item/$SPIKE" | body | history

        r=$(echo "$FIRST" | python3 -c '
import json, sys
i = json.load(sys.stdin)["data"]; i["name"] = "OriPass spike stale"; print(json.dumps(i))' | call PUT "/object/item/$SPIKE" body)
        echo "PUT of the copy read before both changes, its revisionDate two writes old: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        call GET "/object/item/$SPIKE" | body | python3 -c '
import json, sys
i = json.load(sys.stdin)["data"]
print("  the old copy was written over the newer one:", i.get("name") == "OriPass spike stale")'
        echo "after it:"; call GET "/object/item/$SPIKE" | body | history

        # For good from the vault, with no trash between. On 2026-10-11 this
        # answered 200 and the item was still answered for afterwards.
        r=$(call DELETE "/object/item/$SPIKE?permanent=true"); echo "delete for good, never in the trash: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
        swept "$SPIKE"
    fi
    unset SET_HERE P1 P2 P3
    echo "after both:"
    (call GET /list/object/items | body; call GET '/list/object/items?trash=true' | body) | left
fi

say "a child started with the session, three runs"
stop
for run in 1 2 3; do
    t=$(now)
    start "$SESSION" || exit 1
    r=$(call GET /list/object/items)
    echo "run $run: finger to first row (start, then the first list): $(since "$t") s, HTTP $(echo "$r" | code), no /unlock sent"
    if [ "$run" = 1 ]; then
        call GET /status | body | shape
        # The needle goes to python in its environment, not to grep as an
        # argument, where every user on the Mac could read it.
        echo "ps eww from another process shows the session: $(ps eww -p "$CHILD" | NEEDLE="BW_SESSION=$SESSION" python3 -c 'import os,sys; print(sys.stdin.read().count(os.environ["NEEDLE"]))')"
        echo "the session appears in an argument: $(ps -o command= -p "$CHILD" | NEEDLE="$SESSION" python3 -c 'import os,sys; print(sys.stdin.read().count(os.environ["NEEDLE"]))')"
    fi
    stop
done

say "lock for real, then the same session again"
start "$SESSION" || exit 1
r=$(call POST /lock); echo "POST /lock: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
stop
start "$SESSION" || exit 1
r=$(call GET /list/object/items); echo "old session after /lock: HTTP $(echo "$r" | code)"; echo "$r" | body | shape
call GET /status | body | shape
stop
unset SESSION

printf '\nReport written to %s\nRead it, and if it holds no name, address or secret, it is the source for docs/spikes/bw-2026-10.md.\n' "$REPORT"

#!/bin/bash
# OP-59: has `bw` changed what it answers? Run after Homebrew upgrades it, by
# hand, on a real account (`make contract`).
#
# It repeats the shape checks of scripts/spike-bw.sh against a live child and
# lays each answer beside the fixture under Tests/Fixtures/ that stands for
# it. What it prints is keys and type words, one line a difference, and never
# a value: the answers are walked into paths such as `data.data[type=1].name`
# and only those paths are compared. The one exception is the sentence of a
# refusal, which is the CLI's own and which the app reads (`Vault is locked.`).
#
# Everything it sees is printed, and only some of it is a changed answer:
#
#   gone    a key the app stops without (NEEDED, below)             fails
#   type    a key that holds another kind of thing                  fails
#   new     a key bw sends and the fixture lacks: fails only where the
#           fixture claims every key (`whole` in contract-marks.txt)
#   unused  a key the fixture has and no live answer did: a vault with no
#           folder, no one-time code and nothing archived looks like this
#   own     a key the fixture invented (`own` in contract-marks.txt)
#   look    an unused key and a new one side by side, which is also what a
#           renamed key looks like. It does not fail. Read it.
#
# It asks for the master password with `read -s` and hands it to curl on
# standard input, never as an argument. It reads only: no item is made, so
# the answers to a write are not compared, and `item.json` and `folder.json`
# are covered by the items and folders in the lists, which are the same
# objects. The last step locks the CLI for real, and so does the exit trap if
# the run stops early, so the session this run made is dead when it ends.
#
#   1. brew upgrade bitwarden-cli
#   2. make contract                  (or scripts/contract.sh)
#
# `scripts/contract.sh --selftest` needs no `bw` and no account. It compares
# every fixture with itself, and then with copies changed in each of the ways
# above, and fails if a value comes out the other side, a difference is not
# found or a copy is judged the wrong way.
#
# Exit status: 0 when no line fails, 1 when one does, 2 when the run could
# not be made.
#
# The app itself makes no socket file since OP-65: its child serves one
# connected socket. This script still does, because curl cannot be handed a
# socketpair. For as long as it runs, a `bw` with the vault open answers on
# a socket file under the app's run directory to any program running as
# you, with no password. The file is removed on every way out.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$HERE/../Tests/Fixtures"
# The months the fixtures were recorded on (BwVersion.written). A test holds
# this line and that range together.
WRITTEN="2026.9"

export BITWARDENCLI_APPDATA_DIR="$HOME/Library/Application Support/OriPass/bw"
export BW_NOINTERACTION=true
BW=/opt/homebrew/bin/bw
RUN="$HOME/Library/Application Support/OriPass/run"
SOCK="$RUN/contract.sock"
CHILD=

say() { printf '\n## %s\n' "$*"; }

# compare FIXTURE.json: the live answer on standard input against the
# fixture. Prints one line, and under it one line for each key that is gone,
# new or of another type. Status 1 when there is any.
read -r -d '' COMPARE <<'PY' || true
import json, os, re, sys

# What the app stops for when it is missing (ShapeError: Item.init,
# ServeBackend, ServeClient), and a folder's two keys, without which
# Folder.init drops the row and says nothing. Every other key is read if it
# is there. A fixture name ending in * is a prefix.
NEEDED = [
    ("*", "success"),
    ("refused-*", "message"),
    ("list-*", "data.data"),
    ("list-items", "data.data[type=*].name"), ("list-items", "data.data[type=*].type"),
    ("list-trash", "data.data[type=*].name"), ("list-trash", "data.data[type=*].type"),
    ("list-folders", "data.data[].id"), ("list-folders", "data.data[].name"),
    ("generate", "data.data"),
    ("template-*", "data.template"),
    ("status-*", "data.template.status"),
]

def kind(v):
    if v is None: return "null"
    if isinstance(v, bool): return "bool"
    if isinstance(v, (int, float)): return "number"
    if isinstance(v, str): return "string"
    return "list" if isinstance(v, list) else "object"

def walk(v, path, seen, groups):
    seen.setdefault(path, set()).add(kind(v))
    if isinstance(v, dict):
        for k, x in v.items():
            walk(x, path + "." + k if path else k, seen, groups)
    elif isinstance(v, list):
        for x in v:
            # An item list is walked a type at a time: a vault with no SSH key
            # says nothing about what an SSH key looks like. A row of a list
            # route that no longer says it is an item is still one to the
            # app, which asks only for its type. A custom field has a type
            # too and is no item.
            if isinstance(x, dict) and type(x.get("type")) is int \
                    and (x.get("object") == "item" or (path == "data.data" and "object" not in x)):
                sub = "%s[type=%d]" % (path, x["type"])
                groups[sub] = groups.get(sub, 0) + 1
            else:
                sub = path + "[]"
            walk(x, sub, seen, groups)

def shape(text):
    seen, groups = {}, {}
    walk(json.loads(text), "", seen, groups)
    return seen, groups

def under(path, prefix):
    return path == prefix or path.startswith(prefix + ".") or path.startswith(prefix + "[")

def element(path):
    """The nearest list a path is inside: the path up to and including its
    last [] or [type=n], or None for one in no list."""
    cut = max(path.rfind("[]"), path.rfind("]"))
    return path[:cut + 1] if cut >= 0 else None

def named(pattern, name):
    return name.startswith(pattern[:-1]) if pattern.endswith("*") else name == pattern

def any_type(path):
    return re.sub(r"\[type=\d+\]", "[type=*]", path)

def parent(path):
    return path.rsplit(".", 1)[0] if "." in path else ""

# The whole answer is read before anything can end this, so that whoever is
# writing it is never left holding a pipe nobody reads.
live = sys.stdin.read()
fixture, label = sys.argv[1:3]
name = os.path.basename(fixture)[:-len(".json")]
own, whole = set(), []
marks = os.path.join(os.path.dirname(fixture), "contract-marks.txt")
if os.path.exists(marks):
    for line in open(marks):
        words = line.split()
        if len(words) == 3 and not line.startswith("#") and named(words[0], name):
            if words[1] == "own": own.add(any_type(words[2]))
            if words[1] == "whole": whole.append(any_type(words[2]))
needed = {p for n, p in NEEDED if named(n, name)}

want_seen, want_groups = shape(open(fixture).read())
try:
    got_seen, got_groups = shape(live)
except ValueError:
    print("DIFF  %s  %s" % (label, "the answer was not JSON"))
    sys.exit(1)

# Under any type at all, for a key the app reads the same way for every type
# and the fixture happens to carry under another.
anywhere = {any_type(p) for p in want_seen}

# (fails, line). What fails: a key the app needs that is gone, a key added
# where the fixture claims every key, and a type that changed.
lines, unseen = [], 0
went, came = {}, {}
for group in sorted(want_groups):
    if group not in got_groups:
        n = sum(1 for p in want_seen if under(p, group))
        lines.append((False, "note  no live item of this kind, %d keys not compared  %s" % (n, group)))
        want_seen = {p: t for p, t in want_seen.items() if not under(p, group)}
for group in sorted(got_groups):
    if group not in want_groups:
        lines.append((False, "note  live items the fixture has none of  %s (%d)" % (group, got_groups[group])))
for path in sorted(want_seen):
    if path in got_seen:
        continue
    if any(under(any_type(path), o) for o in own):
        lines.append((False, "own     %s  (the fixture's invention)" % path))
        continue
    holder = element(path)
    if holder is not None and holder not in got_seen:
        unseen += 1          # a list that is empty in this vault
        continue
    if any_type(path) in needed:
        lines.append((True, "gone    %s  (the app stops without it)" % path))
    else:
        lines.append((False, "unused  %s" % path))
        went.setdefault(parent(path), []).append(path)
for path in sorted(got_seen):
    if path in want_seen or any(under(path, g) for g in got_groups if g not in want_groups):
        continue
    if any(under(any_type(path), w) for w in whole):
        lines.append((True, "new     %s  (where the fixture claims every key)" % path))
    elif any_type(path) in anywhere:
        lines.append((False, "new     %s  (the fixture has it under another type)" % path))
    else:
        lines.append((False, "new     %s" % path))
        if parent(path) in got_seen and parent(path) in want_seen:
            came.setdefault(parent(path), []).append(path)
for path in sorted(want_seen):
    a, b = want_seen[path] - {"null"}, got_seen.get(path, set()) - {"null"}
    if a and b and not (a & b):
        lines.append((True, "type    %s  %s -> %s" % (path, "/".join(sorted(a)), "/".join(sorted(b)))))
# A key bw renamed looks like a key this vault never uses and a key bw
# added, side by side. Nothing here can tell the two apart, so it is said.
for place in sorted(set(went) & set(came)):
    lines.append((False, "look    %s lost %d and gained %d: a renamed key would look like this"
                  % (place or "the top", len(went[place]), len(came[place]))))
if unseen:
    lines.append((False, "note  %d keys under lists that are empty in this vault, not compared" % unseen))
differs = any(fails for fails, _ in lines)
count = lambda word: sum(1 for _, l in lines if l.startswith(word))
print("%s  %s  %d keys, %d unused, %d new" % ("DIFF" if differs else "ok  ", label, len(want_seen), count("unused"), count("new")))
for _, l in lines:
    print("        " + l)
sys.exit(1 if differs else 0)
PY

# sentence FIXTURE.json: for a fixture that is a refusal, whether the live
# answer on standard input says the same sentence.
read -r -d '' SENTENCE <<'PY' || true
import json, sys
# Read before anything else: leaving early with the answer unread is what
# left `echo` writing into a closed pipe on 2026-10-11.
said = sys.stdin.read()
fixture = json.load(open(sys.argv[1]))
if fixture.get("success") is not False:
    sys.exit(0)
try:
    live = json.loads(said)
except ValueError:
    sys.exit(0)
if live.get("message") != fixture.get("message"):
    print("        sentence  was %r, now %r" % (fixture.get("message"), live.get("message")))
    sys.exit(1)
PY

# check NAME LABEL CODE ANSWER: ANSWER, which is what `call` printed, against
# fixture NAME, and its HTTP status against CODE. LABEL is "GET /route".
check() {
    local name="$1" label="$2" want="$3" status=0 code body said
    code=$(printf '%s\n' "$4" | tail -n 1); body=$(printf '%s\n' "$4" | sed '$d')
    TOTAL=$((TOTAL + 1))
    said=$(printf '%s\n' "$body" | python3 -c "$COMPARE" "$FIXTURES/$name.json" "$name  $label") || status=1
    printf '%s\n' "$said"
    UNUSED=$((UNUSED + $(printf '%s\n' "$said" | grep -c '^        unused ')))
    NEW=$((NEW + $(printf '%s\n' "$said" | grep -c '^        new ')))
    LOOK=$((LOOK + $(printf '%s\n' "$said" | grep -c '^        look ')))
    printf '%s\n' "$body" | python3 -c "$SENTENCE" "$FIXTURES/$name.json" || status=1
    if [ "$code" != "$want" ]; then
        echo "        status  was HTTP $want, now HTTP $code"
        status=1
    fi
    [ "$status" = 0 ] || MISMATCHED=$((MISMATCHED + 1))
}

if [ "${1:-}" = "--selftest" ]; then
    # What the fixtures say is invented; none of it may be printed.
    TMP=$(mktemp -d) && trap 'rm -rf "$TMP"' EXIT
    SELFOUT=$(
        for f in "$FIXTURES"/*.json; do
            n=$(basename "$f" .json)
            [ "$n" = login-recorded ] && continue
            python3 -c "$COMPARE" "$f" "$n" <"$f"
        done
    )
    python3 - "$FIXTURES" "$TMP" <<'PY'
import copy, json, sys
src, out = sys.argv[1:3]
d = json.load(open(src + "/list-items.json"))
rows = d["data"]["data"]
def write(name, change, base=d):
    made = copy.deepcopy(base)
    change(made)
    json.dump(made, open("%s/%s.json" % (out, name), "w"))
def each(change):
    return lambda made: [change(r) for r in made["data"]["data"]]
# A key the app stops without.
write("lost", each(lambda r: r.pop("name", None)))
# Keys this vault never uses: the kind the run of 2026-10-11 cried about.
write("unused", each(lambda r: (r.pop("folderId", None), r.pop("archivedDate", None), (r.get("login") or {}).pop("totp", None))))
# The fixture's own invention, which no bw sends.
write("own", each(lambda r: r.pop("somethingNew", None)))
# A key the fixture has under a login and not under a note or a card.
write("elsewhere", each(lambda r: r.update(fields=[{"name": "selftest-yes", "value": "selftest-yes", "type": 0}], notes="selftest-yes")))
write("gained", each(lambda r: r.update({"selftest-brand-new": {"nested": 1}})))
# One key gone and another come beside it.
write("renamed", each(lambda r: "login" in r and r["login"].update({"selftest-pass": r["login"].pop("password", None)})))
write("turned", each(lambda r: r.update(favorite="selftest-yes")))
# Items that no longer say what they are, which the app does not ask them.
write("unsaid", each(lambda r: r.pop("object", None)))
write("fewer", lambda made: made["data"].update(data=[r for r in rows if r["type"] != 5]))
write("empty", lambda made: made["data"].update(data=[]))
write("bare", each(lambda r: (r.update(fields=[]), (r.get("login") or {}).update(uris=[]))))
# More than a pipe holds, which is what an answer with every item in it is.
write("long", each(lambda r: r.update(notes="selftest-yes " * 20000)))
template = json.load(open(src + "/template-item.json"))
write("template", lambda made: made["data"]["template"].update({"selftest-brand-new": 1}), template)
json.dump({"success": False, "message": "an invented sentence"}, open(out + "/refused.json", "w"))
PY
    OUT=$(
        echo "$SELFOUT"
        for n in lost unused own elsewhere gained renamed turned unsaid fewer empty bare; do
            echo "-- $n"; python3 -c "$COMPARE" "$FIXTURES/list-items.json" "list-items" <"$TMP/$n.json"
        done
        echo "-- template"; python3 -c "$COMPARE" "$FIXTURES/template-item.json" "template-item" <"$TMP/template.json"
        echo "-- refused"; python3 -c "$SENTENCE" "$FIXTURES/refused-locked.json" <"$TMP/refused.json"
        echo "-- not json"; echo 'not json' | python3 -c "$COMPARE" "$FIXTURES/list-items.json" "list-items"
        # Through `check`, as the live run goes, with the signal ignored the
        # way it was under `tee` on 2026-10-11: a writer left with nobody
        # reading says "Broken pipe" here, where otherwise it dies silently.
        echo "-- long"
        (trap '' PIPE; TOTAL=0; MISMATCHED=0; UNUSED=0; NEW=0; LOOK=0
         check list-items "GET /list/object/items" 200 "$(cat "$TMP/long.json"; printf '\n200')" 2>&1
         echo "long: $MISMATCHED of $TOTAL differ, $UNUSED unused, $NEW new, $LOOK to look at")
    )
    echo "$OUT"
    FAILED=0
    SELF=$(echo "$SELFOUT" | grep -c '^ok')
    FIX=$(ls "$FIXTURES"/*.json | grep -vc login-recorded)
    [ "$SELF" = "$FIX" ] || { echo "selftest: FAILED, $SELF of $FIX fixtures match themselves"; FAILED=1; }
    for leaked in selftest-yes CANARY example.com GitHub deniz "Broken pipe"; do
        case "$OUT" in *"$leaked"*) echo "selftest: FAILED, a value came through: $leaked"; FAILED=1;; esac
    done
    # The verdict of each case: the first line under its name.
    for verdict in "lost DIFF" "unused ok" "own ok" "elsewhere ok" "gained ok" "renamed ok" "turned DIFF" \
                   "unsaid ok" "fewer ok" "empty ok" "bare ok" "template DIFF" "long ok"; do
        got=$(echo "$OUT" | grep -A1 "^-- ${verdict% *}\$" | tail -n 1 | cut -c1-4 | tr -d ' ')
        [ "$got" = "${verdict#* }" ] || { echo "selftest: FAILED, ${verdict% *} was judged '$got' and is ${verdict#* }"; FAILED=1; }
    done
    for wanted in "gone    data.data[type=1].name  (the app stops without it)" \
                  "unused  data.data[type=1].login.totp" "unused  data.data[type=1].folderId" \
                  "own     data.data[type=1].somethingNew  (the fixture's invention)" \
                  "new     data.data[type=3].fields  (the fixture has it under another type)" \
                  "new     data.data[type=2].fields[].name  (the fixture has it under another type)" \
                  "new     data.data[type=1].selftest-brand-new" \
                  "unused  data.data[type=1].login.password" "new     data.data[type=1].login.selftest-pass" \
                  "look    data.data[type=1].login lost 1 and gained 1: a renamed key would look like this" \
                  "type    data.data[type=1].favorite  bool -> string" \
                  "unused  data.data[type=1].object" \
                  "new     data.template.selftest-brand-new  (where the fixture claims every key)" \
                  "no live item of this kind" "data.data[type=5]" "empty in this vault" \
                  "was 'Vault is locked.', now 'an invented sentence'" "the answer was not JSON" \
                  "long: 0 of 1 differ, 0 unused, 4 new, 0 to look at"; do
        case "$OUT" in *"$wanted"*) ;; *) echo "selftest: FAILED, not said: $wanted"; FAILED=1;; esac
    done
    [ "$FAILED" = 0 ] && echo "selftest: ok"
    exit "$FAILED"
fi

# ---- the live run ------------------------------------------------------

[ -x "$BW" ] || { echo "no bw at $BW"; exit 2; }
mkdir -p "$RUN" && chmod 700 "$RUN"

now() { python3 -c 'import time; print(time.time())'; }
call() { # call METHOD PATH [body]: the answer, and the HTTP status on a last line of its own
    curl -s --max-time 120 --unix-socket "$SOCK" -X "$1" -w '\n%{http_code}' \
        -H 'Content-Type: application/json' ${3:+--data-binary @-} "http://localhost:8087$2"
}
body() { sed '$d'; }
stop() { [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=; rm -f "$SOCK"; }
trap 'stop; [ -n "${SESSION:-}" ] && BW_SESSION="$SESSION" "$BW" lock >/dev/null 2>&1; rm -f "$RUN/contract.err"' EXIT

TOTAL=0; MISMATCHED=0; UNUSED=0; NEW=0; LOOK=0

say "versions"
FOUND=$("$BW" --version 2>/dev/null | head -n 1)
echo "written for $WRITTEN, found ${FOUND:-nothing}"
case "$FOUND" in
    "$WRITTEN".*|"$WRITTEN") echo "inside the range the fixtures were recorded on" ;;
    *) echo "outside the range: the app still runs, and the differences below are why it may not read everything" ;;
esac

rm -f "$SOCK"
"$BW" serve --hostname "unix://$SOCK" >/dev/null 2>"$RUN/contract.err" &
CHILD=$!
for _ in $(seq 1 400); do
    curl -s --max-time 2 --unix-socket "$SOCK" http://localhost:8087/status >/dev/null 2>&1 && break
    kill -0 "$CHILD" 2>/dev/null || { echo "child exited: $(cat "$RUN/contract.err")"; exit 2; }
    sleep 0.025
done

say "a locked child"
check status-locked "GET /status" 200 "$(call GET /status)"
check refused-locked "GET /list/object/items" 400 "$(call GET /list/object/items)"

say "unlock, wrong password"
R=$(printf '{"password":"not-the-password-%s"}' "$RANDOM" | call POST /unlock body)
check refused-password "POST /unlock" 400 "$R"

say "unlock"
printf 'Master password (not shown, not stored): ' >/dev/tty
IFS= read -rs PW </dev/tty; printf '\n' >/dev/tty
R=$(printf '%s' "$PW" | python3 -c 'import json,sys; sys.stdout.write(json.dumps({"password": sys.stdin.read()}))' | call POST /unlock body)
unset PW
SESSION=$(echo "$R" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["raw"])' 2>/dev/null)
check unlock "POST /unlock" 200 "$R"
[ -n "$SESSION" ] || { echo "no session at data.raw; the rest cannot be read"; exit 2; }
unset R

say "reads"
check status-unlocked "GET /status" 200 "$(call GET /status)"
check list-items "GET /list/object/items" 200 "$(call GET /list/object/items)"
check list-trash "GET /list/object/items?trash=true" 200 "$(call GET '/list/object/items?trash=true')"
check list-folders "GET /list/object/folders" 200 "$(call GET /list/object/folders)"
check list-collections "GET /list/object/collections" 200 "$(call GET /list/object/collections)"
check sync "POST /sync" 200 "$(call POST /sync)"
check generate "GET /generate" 200 "$(call GET /generate)"

say "templates"
for f in "$FIXTURES"/template-*.json; do
    n=$(basename "$f" .json)
    check "$n" "GET /object/template/${n#template-}" 200 "$(call GET "/object/template/${n#template-}")"
done

# 2026.9.1 has no template for a key, and the app makes one of its own keys
# when it is told so in this sentence.
check refused-template "GET /object/template/item.sshkey" 400 "$(call GET /object/template/item.sshkey)"

say "lock"
check lock "POST /lock" 200 "$(call POST /lock)"

say "not compared"
echo "item, folder: the answers to a write, which this run does not make (their objects are the lists')"
echo "refused-premium, 2fa-totp-slice, refused-logged-out: depend on the account, or are not bw's"

say "result"
echo "$UNUSED keys the fixtures have and this vault never used, $NEW keys bw sends that the fixtures lack"
[ "$LOOK" = 0 ] || echo "$LOOK places lost a key and gained one: read the lines that begin 'look'"
if [ "$MISMATCHED" = 0 ]; then
    echo "every shape matches: $TOTAL answers compared, and nothing the app reads has changed"
    exit 0
fi
echo "$MISMATCHED of $TOTAL answers no longer match their fixtures"
exit 1

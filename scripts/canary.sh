#!/bin/bash
# D6, checked and not hoped: after a lock, nothing decrypted is anywhere.
#
# Launches the Debug build with OP_DEMO=tour, which unlocks the demo vault,
# uses it and locks, and then, with the app still running and locked, looks
# for every string in DemoVault.canaries in the places a secret could have
# been left. A hit fails the script and names the place. The list holds each
# canary's SHA-1 too, less the five characters a breach check sends, in
# capitals and in small letters (OP-53).
#
# And D5: the tour starts the stand-in `bw` as the app starts the real one,
# on a connected socket, and for as long as that engine is open this script
# looks under its run directory, and under the app's own, for a socket
# file. There must be none then and none after the lock (OP-65).
#
# And OP-68: Orion's host, started here as anything of his could start it,
# says nothing to a parent that is no browser and is not left running.
#
# And OP-71: the tour asks the door as that host would, from a process of its
# own, through the card, with a copy of the host made here that answers to the
# app where the real one answers to Orion. The login's password, a canary,
# reaches that answer and is searched for everywhere else as before, and the
# file at the socket's path is looked for here after the lock.
#
# And OP-81: through that copy the tour hands the door two canaries as a page's
# passwords, as a toast sends them. They reach the store, the one place they
# may be, and every other place below is searched for them as for the rest.
#
# And D7: that engine is opened by a password out of a seal, and while it is
# open this script reads its environment and its arguments as any process of
# his could, with `ps eww`, for the name BW_SESSION and for every canary,
# the password and the session the stand-in answered with among them. The
# two seals the tour leaves on disk are searched file by file for the
# password each holds, as it is and under base64 (OP-66).
#
#   make canary
#   make canary-installed          the same, over /Applications/OriPass.app
#   OP_LEAK=log make canary        must fail, naming the log
#   OP_LEAK=defaults make canary   must fail, naming the defaults
#   OP_LEAK=tmp make canary        must fail, naming the temporary directory
#   OP_LEAK=seal make canary       must fail, naming the file in the tour's
#                                  seal that holds the password unsealed
#   OP_LEAK=hash make canary       must fail, naming the temporary directory
#   OP_LEAK=pasteboard make canary must fail, naming the pasteboard
#   OP_LEAK=socket make canary     must fail, naming a socket file twice:
#                                  while the engine was open, and after
#
# And D18 with OP-72: the agent's switch on over a shut vault is one listener
# more, at the demo's path and never the real one, and a caller there has a
# list and a signature on one finger, over a key that is a canary.
#
# The tour copies to the general pasteboard, so whatever was on it before a
# run is gone after one.

set -u
cd "$(dirname "$0")/.."
BUNDLE_ID=com.meric.oripass
# OP_APP names another bundle to tour, which is how the installed app is
# searched (`make canary-installed`).
APP=${OP_APP:-$(xcodebuild -project OriPass.xcodeproj -scheme OriPass -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/OriPass.app}
BIN="$APP/Contents/MacOS/OriPass"
[ -x "$BIN" ] || { echo "canary: no build at $APP; run make build"; exit 2; }
HOST="$APP/Contents/Helpers/oripass-bridge"
[ -x "$HOST" ] || { echo "canary: no host for Orion in $APP"; exit 2; }
# The team the app was signed by, which its group and the host's rule name.
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$TEAM" ] && [ "$TEAM" != "not set" ] || { echo "canary: $APP is signed by no team"; exit 2; }

# Outside every directory that is searched: the list is nothing but canaries.
WORK=$(mktemp -d /tmp/oripass-canary.XXXXXX)
CANARIES="$WORK/canaries"
OUT="$WORK/out"
FAILED=0
trap '[ "${OP_LEAK:-}" = pasteboard ] && pbcopy < /dev/null; kill "$PID" 2>/dev/null; rm -rf "$WORK"; rm -f "${TMPDIR:-/tmp}/oripass-leaked-on-purpose.txt"; rm -rf "${TMPDIR:-/tmp}/oripass-tour-seal" "${TMPDIR:-/tmp}/oripass-tour-login" "${TMPDIR:-/tmp}/oripass-tour-recents.json" "${TMPDIR:-/tmp}/oripass-tour-attachments"; defaults delete $BUNDLE_ID leakedOnPurpose 2>/dev/null' EXIT

fail() { echo "canary: FOUND $*"; FAILED=1; }

OP_DEMO=canaries "$BIN" > "$CANARIES"
[ -s "$CANARIES" ] || { echo "canary: the app listed no canaries"; exit 2; }

# A stand-in `bw` for the tour to sign in to: the tests' own, which takes any
# password and any code when it is told neither, and writes down the
# arguments of every start of it.
STANDIN="$WORK/standin"
mkdir "$STANDIN"
cp Tests/Support/standin-bw.py "$STANDIN/bw" && chmod 755 "$STANDIN/bw"
printf '{"fixtures": "%s", "loggedOut": true}' "$PWD/Tests/Fixtures" > "$STANDIN/standin.json"

# The host for the tour to start: the same binary with one string for another
# of its length, so that nothing in it can be told to look elsewhere, signed
# again under the name it had. It lives in $WORK, for this run.
HOST_COPY="$WORK/oripass-bridge"
python3 - "$HOST" "$HOST_COPY" "$TEAM" <<'COPY' || exit 2
import sys
orion = b'anchor apple generic and certificate leaf[subject.OU] = "TFVG979488" and identifier "com.kagi.kagimacOS"'
app = b'anchor apple generic and certificate leaf[subject.OU] = "' + sys.argv[3].encode() + b'" and identifier "com.meric.oripass" '
held = open(sys.argv[1], "rb").read()
if orion not in held:
    print("canary: the host's rule for its parent is not the one this script changes")
    sys.exit(2)
open(sys.argv[2], "wb").write(held.replace(orion, app))
COPY
chmod 755 "$HOST_COPY"
codesign --force --timestamp=none --options runtime --preserve-metadata=identifier,entitlements \
    --sign "Apple Development" "$HOST_COPY" 2>/dev/null \
    || { echo "canary: the copy of the host could not be signed"; exit 2; }

scripts/passes.sh || exit 2
pkill -x OriPass 2>/dev/null
# What a run that was killed under a preview would have left: a file where
# an attachment's copy goes. The app empties that directory as it starts.
ATTACHMENTS="${TMPDIR:-/tmp}/oripass-tour-attachments"
mkdir -p "$ATTACHMENTS/left-by-the-last-run" && echo left > "$ATTACHMENTS/left-by-the-last-run/behind.txt"
touch "$WORK/started"
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
OP_DEMO=tour OP_TOUR_BW="$STANDIN/bw" OP_TOUR_HOST="$HOST_COPY" "$BIN" > "$OUT" 2>/dev/null &
PID=$!
disown "$PID"

# Where a socket file would be: the app's run directory and the tour's
# engine's. The pid is the only thing either may hold.
RUNS=("$HOME/Library/Application Support/OriPass/run" "${TMPDIR:-/tmp}/oripass-tour-login/run")
sockets() { find "${RUNS[@]}" -type s 2>/dev/null | head -1; }
LOOKED=0
OPEN_SOCKET=
HOST_STARTED=
# What `ps eww` printed of the engine's child while it was open, and of
# every child of the app's then.
SEEN="$WORK/seen"
: > "$SEEN"
# One that is there before the tour is not this build's doing: a build from
# before OP-65 that was killed with its vault open leaves `serve.sock`, and
# the two scripts that serve on a file leave theirs if they are killed.
BEFORE=$(sockets)
[ -z "$BEFORE" ] || { echo "canary: a socket file was there before the tour, $BEFORE. Nothing of this build made it: remove it and run again"; exit 2; }

for _ in $(seq 1 300); do
    # Once, with the vault open, its input held open as a browser holds it.
    if [ -z "$HOST_STARTED" ] && grep -q '^tour: unlocked [1-9]' "$OUT" 2>/dev/null; then
        HOST_STARTED=1
        ( { printf '\026\0\0\0{"v":1,"type":"hello"}'; sleep 2; } | "$HOST" chrome-extension://canary/ > "$WORK/host" 2>&1 ) &
    fi
    # Between the engine opening and its being shut, ten times a second.
    if grep -q '^tour: engine: a child' "$OUT" 2>/dev/null && ! grep -q '^tour: engine: shut$' "$OUT"; then
        LOOKED=$((LOOKED + 1))
        [ -n "$OPEN_SOCKET" ] || OPEN_SOCKET=$(sockets)
        for child in $(cat "${RUNS[1]}/child.pid" 2>/dev/null) $(pgrep -P "$PID"); do
            ps eww -p "$child" 2>/dev/null | sed 1d >> "$SEEN"
        done
    fi
    grep -q '^tour: \(locked\|not locked\)$' "$OUT" 2>/dev/null && break
    kill -0 "$PID" 2>/dev/null || { echo "canary: the app quit during the tour"; exit 2; }
    sleep 0.1
done
grep -q '^tour: refused$' "$OUT" || { echo "canary: the tour's wrong password was not refused"; exit 2; }
grep -q '^tour: unlocked [1-9]' "$OUT" || { echo "canary: the tour never unlocked the vault"; exit 2; }
# The password is sealed for a finger and the vault opened with it once, so
# the seal's two files are on disk while everything below is searched.
grep -q '^tour: sealed$' "$OUT" || { echo "canary: the tour sealed no password"; exit 2; }
grep -q '^tour: finger opened [1-9]' "$OUT" || { echo "canary: the tour's finger did not open the vault"; exit 2; }
SEALS=("${TMPDIR:-/tmp}/oripass-tour-seal" "${TMPDIR:-/tmp}/oripass-tour-login/seal")
for seal in "${SEALS[@]}"; do
    [ -s "$seal/password" ] && [ -s "$seal/key" ] || { echo "canary: the tour's seal is not on disk, in $seal"; exit 2; }
    [ -e "$seal/session" ] && fail "a seal of a session, which nothing writes any more, in $seal"
done
# The menu's Lock item locked the vault.
grep -q '^tour: menu locked$' "$OUT" || { echo "canary: the tour's Lock menu item did not lock the vault"; exit 2; }
grep -q '^tour: quick access closed by the lock$' "$OUT" || fail "Quick Access, which the lock did not close ($(grep '^tour: quick' "$OUT"))"
# Raised again over the shut vault, the panel was the lock, its finger opened
# the vault, and the word typed meanwhile was searched for. Return copied a
# password, and the item's id is in a file, which is searched below with the
# rest of the temporary directory and may hold ids and nothing else.
grep -q '^tour: quick access kept what was typed, found [1-9][0-9]*, opened [1-9][0-9]* actions, copied a password and closed, with 1 id kept$' "$OUT" || { echo "canary: the tour's Quick Access went wrong ($(grep '^tour: quick access' "$OUT" | tail -1))"; exit 2; }
# Raised twice more, over a browser on a page and over an app, neither of
# them real: the login for each led the list. Nothing was copied, and what
# was listed is searched for below like everything else.
grep -q "^tour: what is in front: the page's login led the panel, and then the app's$" "$OUT" || { echo "canary: the tour's suggestions went wrong ($(grep '^tour: what is in front' "$OUT" | tail -1))"; exit 2; }
RECENTS="${TMPDIR:-/tmp}/oripass-tour-recents.json"
[ -s "$RECENTS" ] || { echo "canary: the tour's recent items are not on disk"; exit 2; }
grep -qxE '\["[0-9A-Fa-f-]{36}"(,"[0-9A-Fa-f-]{36}")*\]' "$RECENTS" || fail "in the recent items, something that is not an id"
grep -q '^tour: guarded: the finger was asked once, and a second copy and a reveal asked nothing$' "$OUT" || { echo "canary: the tour's item that asks went wrong ($(grep '^tour: guarded' "$OUT" | head -1))"; exit 2; }
grep -q '^tour: guarded: forgotten by the lock$' "$OUT" || fail "an answer for an item that asks, still held after the lock ($(grep '^tour: guarded' "$OUT" | tail -1))"
# A fill (OP-47): the key that fills, over an app that is not real, into a
# sink that posts nothing. Until it was allowed the password was copied, on
# purpose and said. Allowed, the login went key by key and the pasteboard's
# change count did not move, so it never held the password during a fill.
grep -q '^tour: fill: copied and said so until it was allowed, then typed [1-9][0-9]* keys into the app in front with the pasteboard untouched, and none into another$' "$OUT" || { echo "canary: the tour's fill went wrong ($(grep '^tour: fill' "$OUT" | tail -1))"; exit 2; }
# Open & Fill (OP-48): the page it opened is typed into once, by the browser
# it was opened in alone, and the lock forgets one that was never used.
grep -q '^tour: open and fill: opened the address, typed the login once into the page it opened and not into another page or another browser, with the pasteboard untouched$' "$OUT" || { echo "canary: the tour's open and fill went wrong ($(grep '^tour: open and fill' "$OUT" | head -1))"; exit 2; }
grep -q '^tour: open and fill: the page it opened is forgotten by the lock$' "$OUT" || fail "a page armed for a fill, still armed after the lock ($(grep '^tour: open and fill' "$OUT" | tail -1))"
grep -q '^tour: sidebar folded$' "$OUT" || { echo "canary: the tour's ⇧⌘D did not fold the sidebar and bring it back"; exit 2; }
grep -q '^tour: sidebar listed [1-9]' "$OUT" || { echo "canary: the tour did not walk the sidebar's rows"; exit 2; }
grep -q '^tour: list drew [1-9]' "$OUT" || { echo "canary: the tour did not sort, narrow and filter the item list"; exit 2; }
grep -q '^tour: details read [1-9][0-9]* logins and [1-9]' "$OUT" || { echo "canary: the tour did not read the logins' and the other types' details"; exit 2; }
grep -q '^tour: scored [1-9]' "$OUT" || { echo "canary: the tour's passwords were given no levels"; exit 2; }
grep -q '^tour: password health: [1-9] cards over [1-9][0-9]* passwords, and Show Items listed [1-9]' "$OUT" || { echo "canary: the tour's Password Health went wrong ($(grep '^tour: password health' "$OUT" | head -1))"; exit 2; }
# The breach check (OP-53), over a fetcher that answers from memory: every
# password was hashed and asked about by five characters. The hashes are in
# the list of canaries and are searched for below.
grep -q '^tour: breaches: [1-9][0-9]* passwords asked about in [1-9][0-9]* requests, 3 seen, listed and told$' "$OUT" || { echo "canary: the tour's breach check went wrong ($(grep '^tour: breaches' "$OUT" | head -1))"; exit 2; }
# The list of sites that take a one-time code (OP-54), over a source that
# answers from memory: fetched once, compared with every login.
grep -q '^tour: two-factor: [1-9][0-9]* logins without a code in 1 request, listed and told$' "$OUT" || { echo "canary: the tour's two-factor list went wrong ($(grep '^tour: two-factor' "$OUT" | head -1))"; exit 2; }
# A reveal that the next item undid, a copy the delay took back, and then a
# copy and Large Type left for the lock to undo: the pasteboard is searched
# below, with whatever the lock left on it.
grep -q '^tour: revealed [1-9][0-9]* fields, and the next item concealed them$' "$OUT" || { echo "canary: the tour's reveal went wrong ($(grep -E '^tour: .*(reveal|field)' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: copied a password, and the delay cleared it$' "$OUT" || { echo "canary: the tour's copy went wrong ($(grep -E '^tour: .*(cop|⌘)' "$OUT" | tail -1))"; exit 2; }
# A one-time code (OP-46): ⌥⌘C copied six digits made from a secret that is
# a canary. The digits are not one, and the secret is searched for below.
grep -q '^tour: code: ⌥⌘C copied the 6 digits that stand now$' "$OUT" || { echo "canary: the tour's one-time code went wrong ($(grep '^tour: code' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: copied again, and large type is up$' "$OUT" || { echo "canary: the tour left no copy and no Large Type for the lock ($(grep -E '^tour: .*(large|⌘)' "$OUT" | tail -1))"; exit 2; }
# A search by a title, and by a password, which the index does not hold. The
# index is in memory only, and the lock is where it goes.
grep -q '^tour: keys: back, forward, the sheet and the sizes, [0-9]* moved by the keyboard$' "$OUT" || { echo "canary: the tour's keys went wrong ($(grep -E '^tour: .*(⌘|keys)' "$OUT" | grep -v -e '^tour: hot keys' -e '^tour: watching' | head -1))"; exit 2; }
grep -q '^tour: settings: ⌘, raised the window, 8 rooms were drawn and it was put away$' "$OUT" || { echo "canary: the tour's settings window went wrong ($(grep '^tour: settings' "$OUT" | head -1))"; exit 2; }
grep -q '^tour: searched, found [1-9]' "$OUT" || { echo "canary: the tour's search went wrong ($(grep -E '^tour: (no panes to search|⌘F|search found|Esc did not clear the search)' "$OUT" | head -1))"; exit 2; }
grep -q '^tour: changed: a copy made and deleted, and 2 windows are up$' "$OUT" || { echo "canary: the tour's changes went wrong ($(grep -E '^tour: (found no login to change|⌘O opened|the copy was not|⌘Delete)' "$OUT" | head -1))"; exit 2; }
# The editor's form (OP-37): a password typed and saved, which the engine now
# holds with the old one in its history, and then another typed into a form
# that was never saved, which is in no place but the form. Both are canaries
# and are searched for below.
grep -q '^tour: edited: a password saved, the old one kept, and an unchanged form put away$' "$OUT" || { echo "canary: the tour's edit went wrong ($(grep -E '^tour: .*(⌘E|⌘S|Esc|edit)' "$OUT" | tail -1))"; exit 2; }
# The other four forms (OP-38): a code typed into a card, an address into an
# identity, a line into a note and a key pasted over a key's, each saved. The
# code and a line of the pasted key are canaries.
grep -q '^tour: edited the others: a card, an identity, a note and a key saved$' "$OUT" || { echo "canary: the tour's other edits went wrong ($(grep -E '^tour: .*(⌘E|⌘S|others)' "$OUT" | tail -1))"; exit 2; }
# A new item (OP-39): ⌘N, the login's tile, a password typed into the empty
# form and saved. The password is a canary.
grep -q '^tour: made: a new login saved, and the list is on it$' "$OUT" || { echo "canary: the tour made no new login ($(grep -E '^tour: .*(⌘N|⌘S|made|tile)' "$OUT" | tail -1))"; exit 2; }
# The generator (OP-40): a random password, two memorable ones and a PIN made
# by the engine and shown on the card, none of them put in a field or copied.
# Each has a canary in it.
grep -q '^tour: generated: a password of each kind made, none used, and the card put away$' "$OUT" || { echo "canary: the tour's generator went wrong ($(grep -E '^tour: .*generat' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: history: [1-9][0-9]* earlier passwords, one shown and one copied, and the sheet put away$' "$OUT" || { echo "canary: the tour's password history went wrong ($(grep -E '^tour: .*(history|earlier)' "$OUT" | tail -1))"; exit 2; }
# An attachment (OP-44): the one decrypted file this app writes. Nothing was
# left of the run before, the file was fetched into a directory of mode 0700
# and shown, it went when the preview closed, and it was opened again for
# the lock. Its content is a canary, and the temporary directory it was in
# is searched below with the rest.
grep -q '^tour: attachments: nothing left of the last run$' "$OUT" || fail "an attachment's copy from an earlier run, which the launch did not remove ($(grep '^tour: attachments' "$OUT"))"
grep -q '^tour: attachment: fetched and shown, and gone when the preview closed$' "$OUT" || { echo "canary: the tour's attachment went wrong ($(grep -E '^tour: .*attachment' "$OUT" | tail -1))"; exit 2; }
grep -q "^tour: the attachment's copy removed by the lock$" "$OUT" || fail "an attachment's copy, or its preview, after the lock ($(grep "^tour: the attachment's" "$OUT"))"
[ -e "$ATTACHMENTS" ] && fail "the attachments' directory, still there after the lock"
grep -q '^tour: a form is open with a password typed into it$' "$OUT" || { echo "canary: the tour left no form for the lock ($(grep -E '^tour: .*form' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: search index dropped by the lock$' "$OUT" || fail "the search index, still in memory after the lock"
grep -q '^tour: password health: nothing counted after the lock$' "$OUT" || fail "Password Health's lists, still in memory after the lock"
grep -q '^tour: breaches: no answer held after the lock$' "$OUT" || fail "a breach check's answers, still in memory after the lock ($(grep '^tour: breaches' "$OUT" | tail -1))"
grep -q '^tour: two-factor: no list held after the lock$' "$OUT" || fail "the list of two-factor sites, still in memory after the lock ($(grep '^tour: two-factor' "$OUT" | tail -1))"
grep -q '^tour: the form dropped by the lock$' "$OUT" || fail "the editor's form, still in memory after the lock ($(grep '^tour: the form' "$OUT"))"
grep -q '^tour: the generator dropped by the lock$' "$OUT" || fail "the generator, still in memory after the lock ($(grep '^tour: the generator' "$OUT"))"
grep -q '^tour: the history dropped by the lock$' "$OUT" || fail "the password history, still in memory after the lock ($(grep '^tour: the history' "$OUT"))"
grep -q '^tour: item windows closed by the lock$' "$OUT" || fail "a window of one item, still standing after the lock"
grep -q '^tour: pasteboard cleared by the lock$' "$OUT" || fail "on the pasteboard, which the lock did not clear"
grep -q '^tour: large type closed by the lock$' "$OUT" || fail "Large Type, still on the screen after the lock"
# The registry by name (D18). The hot keys are held from launch to quit,
# locked or not, and the tour holds them as the app does, on combinations no
# keyboard has. Open, the auto-lock's timer is there with them. Locked, the
# hot keys are the whole of it: anything else is a timer or a listener that
# outlived the lock.
grep -q '^tour: hot keys 4 taken and 0 refused$' "$OUT" || { echo "canary: the tour's hot keys were not taken ($(grep '^tour: hot keys' "$OUT"))"; exit 2; }
grep -q '^tour: the hot key raised quick access$' "$OUT" || { echo "canary: the tour's hot key did not raise Quick Access"; exit 2; }
# The mark in the menu bar and the app with no window (OP-34): the menu's six
# rows, a click on the mark, every window closed with the Dock switch off, the
# key still raising the panel, and Open from the menu bringing it all back.
grep -q '^tour: the mark: 5 rows, a click raised quick access; with every window closed AppKit asked [1-9][0-9]* times and the Dock icon went, the hot key raised quick access, and Open OriPass brought the window and the Dock icon back$' "$OUT" || { echo "canary: the tour's mark or its closed windows went wrong ($(grep -E '^tour: (the mark|a click|no window|the Dock|with every|the hot key raised nothing|Open )' "$OUT" | tail -1))"; exit 2; }
WATCHING_OPEN=$(sed -n 's/^tour: watching while open: //p' "$OUT")
WATCHING_LOCKED=$(sed -n 's/^tour: watching while locked: //p' "$OUT")
for wanted in HotKeys/hot-keys Lock/idle; do
    case " $WATCHING_OPEN " in
        *" $wanted "*) ;;
        *) fail "a registry without $wanted while unlocked, so it proves nothing ($WATCHING_OPEN)" ;;
    esac
done
[ "$WATCHING_LOCKED" = "HotKeys/hot-keys" ] || fail "a listener or timer live while locked, or no hot keys ($WATCHING_LOCKED)"
# The door for the browser (OP-67): one file, in the group, at the real path,
# for as long as the vault is open.
grep -q '^tour: the door is open with the vault open$' "$OUT" || { echo "canary: the door was not open with the vault ($(grep '^tour: the door' "$OUT" | head -1))"; exit 2; }
case " $WATCHING_OPEN " in
    *" Bridge/door "*) ;;
    *) fail "a registry without Bridge/door while unlocked, so it proves nothing ($WATCHING_OPEN)" ;;
esac
grep -q '^tour: the door went with the lock$' "$OUT" || fail "the door's socket file, still there after the lock"
# The SSH agent (OP-72): off above, so a locked app had the hot keys and
# nothing else. Switched on, it is one listener more, at the demo's path and
# never the real one, and off again it is gone with its file. In between a
# caller had a list and a signature on one finger, over a key that is a
# canary, and the lock cut it.
WATCHING_AGENT=$(sed -n 's/^tour: watching with the agent on: //p' "$OUT")
WATCHING_AFTER=$(sed -n 's/^tour: watching with the agent off: //p' "$OUT")
[ "$WATCHING_AGENT" = "HotKeys/hot-keys SSHAgent/listener" ] || fail "a locked app with the agent on that does not count the agent ($WATCHING_AGENT)"
[ "$WATCHING_AFTER" = "HotKeys/hot-keys" ] || fail "a listener or timer live with the agent off ($WATCHING_AFTER)"
grep -q '^tour: agent: one key listed and a signature a verifier took on one finger, and the lock cut the caller$' "$OUT" || { echo "canary: the tour's agent went wrong ($(grep '^tour: agent' "$OUT" | head -1))"; exit 2; }
grep -q "^tour: the agent's file went with its switch$" "$OUT" || fail "the agent's socket file, still there with its switch off"
# A pass (OP-79): the one timer a locked app may have, beside the agent, and
# what it did before once it is revoked. Its key is the canary above, in
# memory past the lock and searched for with the rest below.
WATCHING_PASS=$(sed -n 's/^tour: watching with a pass: //p' "$OUT")
WATCHING_NO_PASS=$(sed -n 's/^tour: watching with no pass: //p' "$OUT")
[ "$WATCHING_PASS" = "HotKeys/hot-keys SSHAgent/listener SSHAgent/pass" ] || fail "a locked app with a pass that does not count the agent and one timer ($WATCHING_PASS)"
# And OP-88: with a phone beside the pass, one listener more, and without one
# nobody to hear an answer. The file goes with it.
WATCHING_PHONE=$(sed -n 's/^tour: watching with a pass and a phone: //p' "$OUT")
[ "$WATCHING_PHONE" = "HotKeys/hot-keys SSHAgent/approve SSHAgent/listener SSHAgent/pass" ] || fail "a locked app with a pass and a phone that does not count the phone's door ($WATCHING_PHONE)"
[ ! -e "${TMPDIR:-/tmp}/$BUNDLE_ID/agent-demo/approve.sock" ] || fail "the phone's door left a file behind"
[ "$WATCHING_NO_PASS" = "HotKeys/hot-keys SSHAgent/listener" ] || fail "a timer left by a pass that was revoked ($WATCHING_NO_PASS)"
grep -q '^tour: pass: given with one finger, signed a login and a commit over the shut vault with none, and revoked to zeros$' "$OUT" || { echo "canary: the tour's pass went wrong ($(grep '^tour: pass: ' "$OUT" | grep -v '^tour: passkey' | head -1))"; exit 2; }

# And as a host would ask it (OP-71), with what it is given searched for
# below in every place but the answer. The path is written out here, so that
# this does not rest on the app's own word for where the file is.
grep -q '^tour: host: turned away with the switch off, let in on the card, listed a login with no password and was given it$' "$OUT" || { echo "canary: the tour's host went wrong ($(grep '^tour: host' "$OUT" | head -1))"; exit 2; }
grep -q '^tour: passkey: listed one with no key, and after one finger signed so that its public key verified it$' "$OUT" || { echo "canary: the tour's passkey went wrong ($(grep '^tour: passkey' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: code: listed one with no secret, and handed over the code alone$' "$OUT" || { echo "canary: the tour's code went wrong ($(grep '^tour: code' "$OUT" | tail -1))"; exit 2; }
grep -q "^tour: sheet: listed the page in front with no password and filled it, no word found nothing, and a word's login took one finger$" "$OUT" || { echo "canary: the tour's sheet with nothing named went wrong ($(grep '^tour: sheet' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: made passkey: one finger, no key in the answer, and it then signed so that its public key verified it$' "$OUT" || { echo "canary: the tour's made passkey went wrong ($(grep '^tour: made passkey' "$OUT" | tail -1))"; exit 2; }
grep -q "^tour: page's passkey: listed for the page's relying party with no key, another site turned away unasked, and after one finger signed so that its public key verified it$" "$OUT" || { echo "canary: the tour's passkey for a page went wrong ($(grep "^tour: page's passkey" "$OUT" | tail -1))"; exit 2; }
grep -q "^tour: saved: asked by a mark, made a login at the page's origin, stayed quiet for the same password, changed it under one finger and kept the old one, and never asked again$" "$OUT" || { echo "canary: the tour's save went wrong ($(grep '^tour: saved' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: offered: the usernames with no password, and a password the engine made$' "$OUT" || { echo "canary: what a field is offered went wrong ($(grep '^tour: offered' "$OUT" | tail -1))"; exit 2; }
grep -q '^tour: host: after the lock it found no door$' "$OUT" || fail "an answer to a host after the lock ($(grep '^tour: host' "$OUT" | tail -1))"
DOOR="$HOME/Library/Group Containers/$TEAM.oripass/bridge"
[ -e "$DOOR" ] && fail "a file at the socket's path after the lock, $DOOR"
# The sign-in sheet's engine ran, against the stand-in, to an account: a
# password in two children's environments and a code down a pipe.
grep -q '^tour: signed in$' "$OUT" || { echo "canary: the tour did not sign in ($(grep 'sign' "$OUT" | tail -1))"; exit 2; }
grep -q '"--method"' "$STANDIN/arguments.log" || { echo "canary: the stand-in was never started with a method"; exit 2; }
# The engine (OP-65): the same stand-in served one connected socket, was
# opened by a password sent down it and listed its items, and this script
# looked for a socket file while it was open.
grep -q '^tour: engine: a child on a connected socket listed [1-9]' "$OUT" || { echo "canary: the tour's engine went wrong ($(grep '^tour: engine' "$OUT" | head -1))"; exit 2; }
grep -q '"fd+connected://3"' "$STANDIN/arguments.log" || { echo "canary: the stand-in was never started on a connected socket"; exit 2; }
[ "$LOOKED" -gt 0 ] || { echo "canary: the engine was never looked at while it was open"; exit 2; }
[ -z "$OPEN_SOCKET" ] || fail "a socket file while the engine was open, $OPEN_SOCKET"
# What was read of the child is its own, or the search of it means nothing:
# the folder it was told to keep its state in is in its environment.
grep -q 'BITWARDENCLI_APPDATA_DIR=' "$SEEN" || { echo "canary: the engine's environment was never read while it was open"; exit 2; }
grep -q 'BW_SESSION' "$SEEN" && fail "BW_SESSION in the environment of a child, while the engine was open"
grep -qaF -f "$CANARIES" "$SEEN" && fail "in the arguments or environment of a child, while the engine was open"
grep -qaF -f "$CANARIES" "$STANDIN/arguments.log" && fail "in the arguments of a bw that signed in"
grep -q '^tour: locked$' "$OUT" || fail "the store, which is not locked after the tour"
# The log and the defaults are written behind the app's back.
sleep 2

# 1. The app's own folders.
for dir in "$HOME/Library/Application Support/OriPass" "$HOME/Library/Caches/$BUNDLE_ID" \
           "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
           "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/WebKit/$BUNDLE_ID"; do
    [ -e "$dir" ] || continue
    hits=$(grep -rlaF -f "$CANARIES" "$dir" 2>/dev/null)
    [ -z "$hits" ] || fail "on disk, in $(echo "$hits" | head -3 | tr '\n' ' ')"
done

# Restoration writes what was on screen, canary or not, so the folder itself
# is the finding (OP-19).
[ -e "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" ] \
    && fail "a saved window state on disk, which nothing should have written"

# 1b. The seals, file by file, for the password each holds: as it is, and
#     under base64 wherever in a run of three bytes it begins.
python3 - "$CANARIES" "${SEALS[@]}" <<'SEARCH' || FAILED=1
import base64, os, sys
passwords = [line.strip().encode() for line in open(sys.argv[1])
             if line.startswith(("CANARY-MASTER-PASSWORD", "CANARY-SIGNIN-PASSWORD"))]
if len(passwords) != 2:
    print("canary: the list of canaries does not name the two sealed passwords")
    sys.exit(2)
found = False
for seal in sys.argv[2:]:
    for name in sorted(os.listdir(seal)):
        held = open(os.path.join(seal, name), "rb").read()
        for password in passwords:
            # The middle of each encoding, which does not depend on what
            # comes before or after the password.
            coded = [base64.b64encode(b"\0" * shift + password)[4 if shift else 0:-4] for shift in range(3)]
            if password in held or any(form in held for form in coded):
                print("canary: FOUND a sealed password not sealed, in %s" % os.path.join(seal, name))
                found = True
sys.exit(1 if found else 0)
SEARCH

# 2. The temporary directory: whatever was written since the launch.
hits=$(find "${TMPDIR:-/tmp}" -type f -newer "$WORK/started" -print0 2>/dev/null \
    | xargs -0 grep -laF -f "$CANARIES" 2>/dev/null)
[ -z "$hits" ] || fail "in the temporary directory, in $(echo "$hits" | head -3 | tr '\n' ' ')"

# 3. The defaults.
defaults read $BUNDLE_ID 2>/dev/null | grep -qaF -f "$CANARIES" && fail "in the defaults ($BUNDLE_ID)"

# 4. The unified log, for the app's subsystem and its process, over the run.
/usr/bin/log show --start "$STARTED" --info --debug --style compact \
    --predicate "subsystem == \"$BUNDLE_ID\" OR process == \"OriPass\"" 2>/dev/null \
    | grep -qaF -f "$CANARIES" && fail "in the log"

# 5. The general pasteboard.
pbpaste 2>/dev/null | grep -qaF -f "$CANARIES" && fail "on the pasteboard"

# 6. Every process the app started: none should be alive, and none that is
#    should carry a canary in its arguments or its environment.
CHILDREN=$(pgrep -P "$PID" | tr '\n' ' ')
for child in $CHILDREN; do
    fail "a child still running after the lock (pid $child)"
    ps eww -p "$child" | grep -qaF -f "$CANARIES" && fail "in the arguments or environment of pid $child"
done
ps eww -p "$PID" | grep -qaF -f "$CANARIES" && fail "in the app's own arguments or environment"

# 6b. Orion's host, which outlives nobody, and which told a stranger nothing.
[ -n "$HOST_STARTED" ] || { echo "canary: the host was never started"; exit 2; }
LEFT=$({ pgrep -f "$HOST"; pgrep -f "$HOST_COPY"; } | tr '\n' ' ')
[ -z "$LEFT" ] || fail "a host for Orion still running after the tour (pid $LEFT)"
[ -s "$WORK/host" ] && fail "an answer from the host to a parent that is no browser"

# 7. A socket file, which nothing makes any more, and anything at all left
#    where the engine ran: its pid is written down only while it lives.
LEFT=$(sockets)
[ -z "$LEFT" ] || fail "a socket file after the lock, $LEFT"
LEFT=$(ls -A "${RUNS[1]}" 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] || fail "in the engine's run directory after the lock: $LEFT"

if [ "$FAILED" = 0 ]; then
    echo "canary: nothing found. $(wc -l < "$CANARIES" | tr -d ' ') canaries and hashes of them, $(sed -n 's/^tour: unlocked //p' "$OUT") seen and locked away."
fi
exit $FAILED

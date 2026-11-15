#!/bin/zsh
# Says no when the OriPass that is running holds an SSH pass, before a script
# quits it. A pass is in that app's memory and nowhere else, so quitting it
# ends every pass, and the request after that waits for a finger at the Mac
# that may not be there: on 2026-11-03 an install did this to a 24-hour pass
# with nobody at the Mac, and every commit and login after it hung.
#
#   scripts/passes.sh [socket]   exits 1 with a sentence while a pass stands
#
# It asks the agent `passes@oripass`, which answers a count and nothing else.
# No socket, no answer, or an app from before the question, is no pass.
# OP_END_PASSES=1 lets the script go on and end them.
set -u

SOCKET=${1:-$HOME/.oripass/agent.sock}
[ -S "$SOCKET" ] || exit 0
COUNT=$(python3 -I - "$SOCKET" <<'ASK'
import socket, struct, sys
name = b"passes@oripass"
body = bytes([27]) + struct.pack(">I", len(name)) + name
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(struct.pack(">I", len(body)) + body)
    answer = b""
    while len(answer) < 9:
        part = s.recv(9 - len(answer))
        if not part:
            break
        answer += part
except OSError:
    answer = b""
if len(answer) == 9 and answer[4] == 6:
    print(struct.unpack(">I", answer[5:9])[0])
else:
    print(0)
ASK
)
[ "${COUNT:-0}" -gt 0 ] || exit 0
[ "${OP_END_PASSES:-}" = 1 ] && exit 0
if [ "$COUNT" = 1 ]; then held="an SSH pass"; else held="$COUNT SSH passes"; fi
echo "OriPass is holding $held, and quitting it ends them; nothing was quit. OP_END_PASSES=1 ends them on purpose." >&2
exit 1

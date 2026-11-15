#!/bin/bash
# OP-73: put OriPass's agent in this session's environment, if the agent is
# there. With no matcher in hooks.json this runs at every start of a session,
# a resume, a /clear and a compaction, so it may find its own line already in
# the file. It prints nothing: what a SessionStart hook prints is put in front
# of the model.

SOCKET="$HOME/.oripass/agent.sock"

[ -n "$CLAUDE_ENV_FILE" ] || exit 0
[ -S "$SOCKET" ] || exit 0

# A file with nobody listening is what a killed app leaves. This connects and
# sends nothing: `ssh-add -l` would be a request, and over a shut vault a
# request asks for a finger, at every session anyone starts.
/usr/bin/nc -U -w 1 "$SOCKET" </dev/null >/dev/null 2>&1 || exit 0

LINE=$(printf 'export SSH_AUTH_SOCK=%q' "$SOCKET")
grep -qxF "$LINE" "$CLAUDE_ENV_FILE" 2>/dev/null || printf '%s\n' "$LINE" >>"$CLAUDE_ENV_FILE"

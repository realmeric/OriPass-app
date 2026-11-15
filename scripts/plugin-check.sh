#!/bin/bash
# OP-73: does the Claude Code plugin under Plugins/claude-code do what its card
# says? Run under `make test` by PluginScriptTests, and by hand with no
# arguments.
#
# The hook is run the way Claude Code runs it, from the command in hooks.json
# through `sh -c`, against OpenSSH's own ssh-agent on a temp socket, with a
# throwaway key and a HOME made here, so nothing of this Mac's agent, keys or
# ~/.ssh is touched and OriPass does not have to be running. The path is under
# /tmp and short because a socket's is held to 104 bytes. HOME has a space in
# it because a hook's line goes through a shell.
#
# Exit status: 0 when every case holds, 1 at the first that does not.

set -u

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)/Plugins/claude-code"
WORK=$(mktemp -d /tmp/oripass-plugin.XXXXXX) || exit 1
FAKE_HOME="$WORK/a home"
SOCKET="$FAKE_HOME/.oripass/agent.sock"
ENV_FILE="$WORK/session-env.sh"
AGENT_LOG="$WORK/agent.log"
TIDY="$WORK/tidy"
AGENT=

cleanup() {
	[ -z "$AGENT" ] || kill_agent
	rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$FAKE_HOME/.oripass" "$TIDY"
chmod 700 "$FAKE_HOME/.oripass"

fail() {
	echo "plugin-check: FAILED: $*"
	exit 1
}

start_agent() {
	rm -f "$SOCKET"
	/usr/bin/ssh-agent -d -a "$SOCKET" >/dev/null 2>"$AGENT_LOG" &
	AGENT=$!
	for _ in {1..50}; do
		[ -S "$SOCKET" ] && return
		perl -e 'select undef, undef, undef, 0.1'
	done
	fail "ssh-agent made no socket"
}

# A kill that gives the agent no chance to tidy leaves its file behind, which
# is what an app that was killed would leave.
kill_agent() {
	kill -9 "$AGENT"
	wait "$AGENT" 2>/dev/null
	AGENT=
}

# The hook, from an empty directory. Its first argument is the value of
# CLAUDE_ENV_FILE, or nothing for a session that has none.
run_hook() {
	local command
	command=$(plutil -extract hooks.SessionStart.0.hooks.0.command raw -o - "$PLUGIN/hooks/hooks.json") ||
		fail "hooks.json has no SessionStart command"
	local environment=(HOME="$FAKE_HOME" PATH=/usr/bin:/bin CLAUDE_PLUGIN_ROOT="$PLUGIN")
	[ -z "${1:-}" ] || environment+=(CLAUDE_ENV_FILE="$1")
	SAID=$(cd "$TIDY" && env -i "${environment[@]}" /bin/sh -c "$command" 2>&1)
	STATUS=$?
	[ "$STATUS" -eq 0 ] || fail "the hook exited $STATUS: $SAID"
	[ -z "$SAID" ] || fail "the hook printed, and that goes to the model: $SAID"
	[ -z "$(ls -A "$TIDY")" ] || fail "the hook left a file where it ran"
}

lines_of() {
	[ -e "$1" ] || { echo 0; return; }
	grep -c . "$1"
}

# A shell of each kind Claude Code may run a command in, reading the env file
# first as it does, and given only what a session would have anyway.
through_env_file() {
	local shell=$1
	shift
	env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin SSH_AUTH_SOCK=/before ENV_FILE="$ENV_FILE" \
		"$shell" -c '[ ! -e "$ENV_FILE" ] || . "$ENV_FILE"; "$@"' sh "$@"
}

for file in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
	plutil -convert xml1 -o /dev/null "$PLUGIN/$file" || fail "$file is not JSON"
done
NAME=$(plutil -extract name raw -o - "$PLUGIN/.claude-plugin/plugin.json")
LISTED=$(plutil -extract plugins.0.name raw -o - "$PLUGIN/.claude-plugin/marketplace.json")
[ "$NAME" = "$LISTED" ] || fail "the manifest says $NAME and the marketplace $LISTED"
[ "$(plutil -extract plugins.0.source raw -o - "$PLUGIN/.claude-plugin/marketplace.json")" = "./" ] ||
	fail "the marketplace does not point at its own folder"
sed -n '/^---$/,/^---$/p' "$PLUGIN/skills/ssh/SKILL.md" | grep -q '^description: ' ||
	fail "the skill has no description for a session to find it by"

# No socket: nothing is written and the session keeps what it had.
run_hook "$ENV_FILE"
[ "$(lines_of "$ENV_FILE")" -eq 0 ] || fail "wrote to the env file with no socket"
[ "$(through_env_file /bin/bash printenv SSH_AUTH_SOCK)" = /before ] ||
	fail "the environment changed with no socket"
echo "no socket: nothing written"

# A plain file at the path is no socket.
: >"$SOCKET"
run_hook "$ENV_FILE"
[ "$(lines_of "$ENV_FILE")" -eq 0 ] || fail "took a plain file for a socket"
rm -f "$SOCKET"

# A socket with nobody behind it is no agent.
start_agent
kill_agent
[ -S "$SOCKET" ] || fail "a killed agent left no socket to test with"
run_hook "$ENV_FILE"
[ "$(lines_of "$ENV_FILE")" -eq 0 ] || fail "took a dead socket for an agent"
echo "dead socket: nothing written"

# An agent, and no CLAUDE_ENV_FILE to tell.
start_agent
run_hook ""
echo "no env file: nothing written"

# An agent and an env file another hook has already written to. The hook must
# send the agent nothing, since a request over a shut vault asks for a finger:
# the first thing the agent is asked by anyone must be the ssh-add below it.
echo 'export ANOTHER_HOOK=kept' >"$ENV_FILE"
run_hook "$ENV_FILE"
[ "$(lines_of "$ENV_FILE")" -eq 2 ] || fail "wrote $(lines_of "$ENV_FILE") lines, wanted 2"
[ "$(through_env_file /bin/bash printenv ANOTHER_HOOK)" = kept ] || fail "lost another hook's line"

ssh-keygen -q -t ed25519 -N '' -C throwaway -f "$WORK/key" || fail "ssh-keygen"
SSH_AUTH_SOCK="$SOCKET" ssh-add -q "$WORK/key" || fail "ssh-add"
rm -f "$WORK/key"
ASKED=$(grep -c 'process_message' "$AGENT_LOG")
[ "$ASKED" -eq 1 ] || fail "the agent was asked $ASKED things, and ssh-add is one"

for shell in /bin/bash /bin/zsh; do
	[ "$(through_env_file "$shell" printenv SSH_AUTH_SOCK)" = "$SOCKET" ] ||
		fail "$shell did not get the socket"
	[ "$(through_env_file "$shell" ssh-add -L)" = "$(cat "$WORK/key.pub")" ] ||
		fail "ssh-add -L through $shell did not list the key"
done
echo "agent: ssh-add -L lists the key through what the hook wrote"

# The only copy of the private half is in the agent now, so a signature that
# checks came through it.
echo 'a message' >"$WORK/message"
through_env_file /bin/bash ssh-keygen -q -Y sign -n op73 -f "$WORK/key.pub" "$WORK/message" >/dev/null 2>&1 ||
	fail "the agent would not sign through what the hook wrote"
ssh-keygen -q -Y check-novalidate -n op73 -f "$WORK/key.pub" -s "$WORK/message.sig" <"$WORK/message" >/dev/null ||
	fail "the agent's signature did not check"
echo "agent: a signature through what the hook wrote checks"

# SessionStart fires again on a resume, a /clear and a compaction.
run_hook "$ENV_FILE"
[ "$(lines_of "$ENV_FILE")" -eq 2 ] || fail "a second firing left $(lines_of "$ENV_FILE") lines"
echo "second firing: no second line"

echo "plugin-check: ok"

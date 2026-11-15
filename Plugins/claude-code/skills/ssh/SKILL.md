---
name: ssh
description: How to reach a remote host from this Mac, through OriPass's SSH agent. Use before ssh, scp, sftp or rsync, before git over ssh (push, pull, fetch, clone), and when one of them fails with an authentication error.
---

The keys are in the person's vault and OriPass signs with them, so ssh here is a request to a person: the private half stays in OriPass, and this session only ever sees a signature.

Run plain `ssh`, `scp`, `sftp`, `rsync` and `git` as you would anywhere, in the foreground, with the options the task needs and no identity option. `$SSH_AUTH_SOCK` already points at the agent.

## A finger may be asked for

OriPass may ask for a finger on the Mac before it signs, and a listing with `ssh-add -l` counts too, since a shut vault has to be opened to list anything. Before a command that may ask, tell the person in one line what is about to run and on which host, so they know to look at the Mac. Then wait for the command to return. They have sixty seconds.

## When it fails

Stop on the first failure of this kind and tell the person what the command printed:

- `agent refused operation`, `communication with agent failed` or `Permission denied (publickey)`: they refused, nobody answered within the sixty seconds, or the key is not one this host takes.
- `Error connecting to agent`, or `$SSH_AUTH_SOCK` not ending in `.oripass/agent.sock`: the agent was not running when this session started. It comes back when the person switches on the SSH agent in OriPass's settings and opens a new session.

The person decides what happens next, so run the same command again only when they say to. A refusal is their answer. Reaching the host another way, with a key from disk, a new key, a token in a URL or a password, is theirs to arrange. A private key or a passphrase is something this session has no use for, so leave it unasked for and leave `~/.ssh` unread.

Adding a key through `ssh-add` always fails here, because the vault is where keys are added.

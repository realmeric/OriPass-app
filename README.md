# OriPass

A Mac app for a Bitwarden account. You get three panes, a lock screen that opens with a finger, a search panel on a key from any app, a mark in the menu bar, an editor, a password generator, a page that counts your weak and reused passwords, a menu of your logins under a page's fields in Safari and Orion, a place in the system's Passwords menu, and a login typed for you into whatever other app is in front.

OriPass is unofficial: it is not made by, affiliated with or endorsed by Bitwarden or by 1Password, and it uses Bitwarden's own command line client, which you install yourself. Bitwarden is a trademark of Bitwarden, Inc., 1Password of AgileBits Inc., and all other trademarks belong to their owners.

It replaces Bitwarden's desktop app and, in Safari and Orion, its browser extension. Your vault stays on Bitwarden's server, your phone keeps its app, and any other browser keeps Bitwarden's extension. On the Mac, Bitwarden's own command line client, `bw`, does every login, sync, decryption and write. OriPass starts it, talks to it and draws what it answers. It derives no key and decrypts nothing itself.

Read "What it is not" before you trust it with anything. One paragraph there is about who else on your Mac can ask for your vault while it is unlocked.

## What you need

A Mac with Apple Silicon on macOS 27. The build is arm64 only and will not start on anything older.

A Bitwarden account, on bitwarden.com, on bitwarden.eu or on a server of your own that answers over https. You sign in inside the app with your email and master password or with your personal API key. A second step by authenticator app or by emailed code is asked for in the same sheet.

`bw`, from Homebrew:

    brew install bitwarden-cli

OriPass looks for it at `/opt/homebrew/bin/bw`, then on your `PATH`, or at a path you give it in Settings, Account. It was written against 2026.9. With a newer one it tells you so in that room and keeps working until an answer comes back in a shape it does not know.

Touch ID, if you want the finger. Without it the app works and asks for your master password at every unlock. With the lid shut and an outside keyboard there is no sensor, so it is the password then too.

Xcode 27, `xcodegen` and a signing certificate under an Apple team of your own, because nobody hands you a built copy. `make install` needs a Developer ID certificate and a notary profile, which take Apple's paid developer programme. With a free Apple Development certificate you have `make run` and `make test` and no installed copy.

## Building it

No file in this repository names a team. Put yours in `Team.xcconfig` at the top of the checkout, which git ignores, as one line:

    OP_TEAM = <your team id>

or set `OP_TEAM` in the environment, which wins. Every build signs with it, the entitlements name the app group `<team>.oripass` from it, and the app reads its own team from its signature at run time, so the door for the browser takes only helpers signed by the same team. The iPhone app has a `Team.xcconfig` of its own under `Phone/` (`Phone/README.md`).

    xcrun notarytool store-credentials oripass --apple-id <your Apple ID> --team-id <your team id>
    OP_NOTARY_PROFILE=oripass \
        OP_APP_PROFILE=<path> OP_AUTOFILL_PROFILE=<path> make install

The first line keeps an app-specific password in your keychain under the name `oripass`. The two paths are Developer ID provisioning profiles from Apple's developer site, for `com.meric.oripass` and `com.meric.oripass.autofill`, each with the AutoFill Credential Provider capability. Leave out both and the build leaves out the system's AutoFill and says so. One without the other stops. The second line makes a Release build in `$TMPDIR`, puts those profiles in it, signs the Safari extension, the AutoFill provider if it has one, the helper and the app with your Developer ID certificate and the hardened runtime, checks the signatures, the entitlements, the profiles, that macOS lists the extensions and that the app starts and shows its lock screen, sends the build to Apple, staples the ticket, and only then replaces `/Applications/OriPass.app`. Without `OP_NOTARY_PROFILE` it stops before it builds anything, and with no team it stops before that. `make release` stops short of Apple and the copy, and keeps nothing. Both quit an OriPass that is running, without asking.

To look at it without an account, `OP_DEMO=1 make run` puts an invented vault of forty items behind the lock screen. Its password is `demo`. `make run` and `make test` are Debug builds that Xcode signs with your Apple Development certificate, under the same team.

## The keys

⌥⌘\ opens Quick Access from any app, ⇧⌘L locks, and ⌘\ fills the app in front. In Quick Access, Return copies the password and closes, ⇧Return types the login into the app you came from, and → opens everything else you can do with the item. ⌘/ inside the window lists the rest. The three that work from anywhere can be changed in Settings.

## The extension

Safari and Orion share one extension, which puts a mark on any field a login could go in and draws a menu under it, offers to save a login when a page takes one, and offers your passkey when a page asks for one. In a page's top frame it hides Safari's own key button and its Strong Password words inside a field, with one small style sheet that touches nothing else on the page. A click on that key was one way to the Passwords menu, and that way is gone there, while the suggestions macOS shows when you click into a field stay. The extension needs a copy from `make install`, since a Debug build does not carry it, and it works while the app is running with its vault open.

In Safari, tick OriPass under Safari, Settings, Extensions.

In Orion, turn on Let Orion reach OriPass in Settings, Filling, then install the extension under Tools, Extensions, Install from Disk, pointing it at `/Applications/OriPass.app/Contents/PlugIns/OriPassSafari.appex`. If Orion will not take that, `make extension` writes the same files as `build/OriPass-extension.zip`. The first time the extension asks, a card names it and you allow or deny it. Settings, Filling lists what you answered and takes it back.

## What it sends, and to whom

`bw` talks to your Bitwarden server, as it would from a terminal. OriPass itself makes three kinds of request and no others.

Site icons, on until you switch them off. For each login whose row you look at, it asks `icons.bitwarden.net` for that site's icon, which tells Bitwarden's icon server which sites you have logins for. Bitwarden's own apps do the same. Switched off, you get lettered tiles and nothing is asked.

Breached passwords, off until you switch it on. It sends the first five characters of a SHA-1 hash of each password to `api.pwnedpasswords.com`, which is Have I Been Pwned, and compares the rest of the hash on your Mac.

The two-factor list, off until you switch it on. Once a week it fetches a public file from `api.2fa.directory` listing the sites that take a one-time code, and compares it here with the addresses of your logins. Nothing of yours is sent. Data sourced from 2FA Directory by 2factorauth.

All three switches are in Settings, Privacy. There is no analytics, no crash reporter and no update check. The app loads no page itself. Your browser is handed an address only when you ask: a click on a login's website or on a link in a note, Open & Fill for a login, and in Settings the buttons for the web vault and for the Public Suffix List. An address from your vault goes over as http or https or not at all, so anything else written in a note stays text.

What crosses to a browser stays on your Mac, and crosses only while the vault is open. For the page you are on, the extension is given an id, a title and a username for each login saved for that site, and no password. A password crosses when you choose a row of its menu on that page, and at no other time: that login's username, password and one-time code go into the page's fields, after a finger or your master password if the item asks again. The login's address is held to the page again first, as the browser names the page. A page on `http:` gets nothing for a login saved under `https:`, and an item in the trash or the archive gets nothing. Once a password is in a field, the page can read it, as it can what you type. With the vault locked or the app closed the extension gets nothing and says so.

On a site with no login, the same menu lists the usernames and email addresses your logins already use, most used first, at most eight, and your identities' emails behind them. These cross with no title, no id and no address. They stay in the extension's own drawing, where a page cannot read them, and only the one you choose goes into the field. A password field in a sign-up offers a new password instead: the app has `bw` make one by your generator's settings, or a random one if those say PIN, and it goes into that form's new password fields when you choose the row. The vault does not hold it until you press New Login on the toast that comes when the site takes it. Dismiss that toast and the password is the site's alone.

A password also crosses the other way. When you send a form with a password in it, the extension reads the username and the password and holds them in your browser's memory for two minutes at most, never on disk. If the page then lets you in, it asks the app whether it knows that password, by a hash made under a key used once, so the password itself does not cross to ask. If it does not, a toast at the top right offers New Login or Update. The password crosses to the app only when you press one, and is written to your vault at the site's address as your browser named it. An update takes a finger or your master password every time, and the old password stays in the item's history. Same password: nothing is shown. Never for this site keeps that host in the settings, and Settings, Filling takes it back. A page cannot read the toast or press it, though a page that went looking could tell that something is drawn over a corner of it.

The system's AutoFill gets the same and no more. Pick OriPass from the Passwords menu and the sheet asks the open vault for an id, a title and a username for each login that holds for what the system named. A password crosses when you choose a row, after a finger or your master password if the item asks again, and goes to macOS to fill. For an app, a login is offered as Quick Access offers one, by the app's name and its bundle id, so read the name on the sheet before you choose. A browser may name nothing at all, Orion for one. Then the app looks at what is in front, as Quick Access does, asking the browser for its page if macOS allows that, and lists that page's logins. A field on the sheet finds any other login by a word, at most eight rows of an id, a title and a username, and one chosen that way always takes your finger or your master password, because no address holds it to anything. The sheet writes nothing, and with the vault locked or the app closed it gets nothing and says so.

A passkey goes the same way, and its key stays in the app. When a page asks for one and you pick OriPass, the sheet gets an id, a title and a username for each passkey for that site. Choose a row and the app asks for a finger, or your master password if there is no finger to ask, every time and for every item, then signs what the page sent and hands macOS the signature. Only keys made with P-256 are answered. Whether macOS offers OriPass to a page with nothing on its list is not known yet. If it does not, Settings, Privacy has a switch, off by default, that writes each passkey's site, username and credential id into the system's list while the vault is open, and takes them out at the lock, at a quit and at launch.

The extension can answer a page's passkey request itself. It puts one small script of its own in each `https:` page's top frame, in the page's reach, and that script holds nothing. To know whether to stand aside, the extension asks the app once for each such page whether the vault has a passkey for that site, so the address of every `https:` page you open crosses to the app, and nothing of it is kept there. With a yes the script passes on what the page asks for and hands back the answer, and with anything else it leaves the request to the browser. If the vault has a passkey for that page's own site, a toast offers Sign In and Not Now. The list crosses as an id, a title and a username. Sign In takes a finger, or your master password if there is no finger to ask, every time. The extension writes the client data from the address the browser gave it, the app signs its hash, and the signature goes to the page. The key does not leave the app. Not Now hands the request to the browser's own, so the system's sheet is still there, and a refused finger tells the page no. With no passkey for the site, or a locked vault, the page never hears from OriPass. A page that sets out to can tell the two apart from the timing of its own requests: it can learn that an open vault holds a passkey for that site, and not for whom. A page cannot press the toast. A mark on a site with a passkey has a small key beside it, from the same question.

A one-time code is the same again, and its secret stays in the app. When the system asks OriPass for a code, the sheet gets an id, a title and a username for each login for that site or app that has a code. Choose a row, after a finger or your master password if the item asks again, and the app makes the code and hands macOS that alone.

Two things happen on the Mac that are not requests. Quick Access asks Safari, Brave or Orion for the address of the tab in front, to put that site's login first, and so does the AutoFill sheet when the system does not say what it is for. macOS asks your leave the first time for each browser. Filling posts key events to the app in front, which needs Accessibility, and you are asked at the first fill and not before.

## What it leaves on your disk

Nothing decrypted, with two exceptions. An attachment you preview is written to a private folder under `$TMPDIR` and removed when the preview closes, and again at the lock, when you quit and at launch. And with "List passkeys with the system" switched on, which it is not until you do it, each passkey's site, username and credential id go into a database of the system's while the vault is open. No key goes there. The lock and a quit empty it, and a launch empties what a killed run left.

`~/Library/Application Support/OriPass/bw/` is `bw`'s own folder, holding your vault as the server sent it, encrypted. It is separate from the one a `bw` in your terminal uses, so the two logins do not see each other. `seal/` beside it holds your master password, if you said yes to Touch ID: sealed to a key in the Secure Enclave that answers only to a finger enrolled when you typed it, and never in the clear. After fourteen days the app will not open it, and deletes it the next time the lock screen appears. Until then the two files are still on your disk, and the fourteen days are the app's own reading of a date kept beside the seal, by your Mac's clock. The enclave enforces the finger and not the age. Enrol or remove a fingerprint and the enclave key stops answering at once. The app is written to notice that and delete the files at the next lock screen, which nobody has yet watched it do on a real sensor. Say no and it is stored nowhere. "Lock and forget" deletes it there and then. `recent.json` holds the ids of the ten items you last used through Quick Access.

With Let Orion reach OriPass on in Settings, Filling, `~/Library/Application Support/Orion/NativeMessagingHosts/com.meric.oripass.bridge.json` tells Orion where the app's helper is. It holds that path and the extensions you let in, and it goes when the switch does. Your answers to the card are in the app's settings, as each extension's origin.

`~/Library/Caches/com.meric.oripass/icons/` holds one file per site, named after the site. So that folder lists, in file names, the sites you have logins for, and it stays when you lock. Signing out in Settings removes it, and so does

    rm -rf ~/Library/Caches/com.meric.oripass/icons

With the SSH agent switched on, `~/.oripass/agent.sock` is there while the app runs, a socket in a folder only you can read. It holds nothing: no key and no public key is on disk. A phone you added keeps its public key in the app's settings, and `~/.oripass/approve.sock` stands beside the agent's socket only while a pass does. The app never writes to `~/.ssh`. It reads one file there, `known_hosts`, once, as a pass is given, and keeps the host keys in memory for as long as the pass stands.

The system's log keeps one line for each time the app reads the vault's lists, for as long as macOS keeps its log. It says how many items, trashed items and folders came back and how many were missing, and nothing about any of them.

What you copy is marked so that clipboard managers which honour the mark skip it, is kept off Universal Clipboard, and is cleared after ninety seconds, at the lock or when you quit, whichever comes first, if it is still what the app put there.

The app locks when the Mac sleeps, when the screen locks or the screen saver starts, when you switch user, when you quit, and after ten idle minutes. A lock kills `bw` and drops every item from memory. The one exception is an SSH pass you gave, which keeps every SSH key's private half in memory, on no disk, through a lock until it ends (see below).

## The SSH agent

Off until you switch it on, in Settings, Developer. OriPass then answers OpenSSH's agent protocol at `~/.oripass/agent.sock` with the SSH Key items in your vault, Ed25519, ECDSA and RSA, in OpenSSH's own file format with no passphrase. It lists them and signs with them, and does nothing else: a key cannot be added or taken out through it. A private key stays in the vault and is out of it for one signature.

OriPass does not touch `~/.ssh/config`. The room shows the one line it needs and copies it, and you add it under `Host *`:

    IdentityAgent ~/.oripass/agent.sock

The first signature with a key asks for your finger, or your master password with no finger to ask, and a card in the middle of the screen says what is wanted, such as signing a commit or pushing to a host, and names who is asking: `ssh`, what started it, and the app at the top. Touch the sensor with the card up: it needs no click, and the app you were in stays in front. The card also names the key, the folder when `git` is asking, and where `ssh` says it is going, with the fingerprint of the host key that host showed under it, which is the proof, since a command line is only what a process says. To read the host, the app reads the arguments of the `ssh` that connected. It keeps the host and whether `git` is pushing or fetching for the card, and nothing else of them. A yes is for that key and that app, for ten minutes unless you choose each use or until the lock, in Settings or on the card for that one answer. So a yes to `ssh` in Terminal is a yes to anything else running in Terminal, for that key, for those minutes. The names are file names, and a program can call itself `ssh`. A connection that reached the agent by forwarding is asked every time, and nobody answering in sixty seconds is a no.

With the vault locked the app has no list of keys, so the first request asks for your finger, with the same card naming who asked, and that finger opens the vault and answers for the signature after it. With no password kept for Touch ID, or with the lid shut over the sensor, the request fails and the lock screen says why. A lock forgets every yes and cuts every connection. Any process running as you can connect to the socket and raise that question, as with any ssh-agent. It gets nothing unless you answer.


### A pass, for when you are away

A pass lets one app go on signing while nobody is at the Mac, for one hour, four, eight or twenty-four, and it is given with one finger. It is for the whole of that app and everything it starts, with every SSH key in your vault. On a card that is the switch "Keep allowing while I'm away", which any card from a signed app has unless it came by forwarding. In Settings, Developer, New Pass does it before you leave. An app has one pass, and a new one replaces the last.

While it stands, two things are signed with nobody asked, the vault open or shut. A login, on a session the host itself signed, to a host whose key was in `~/.ssh/known_hosts` when the pass was given or that you have answered for with a finger since. And a git commit or tag, which is what `git` asks `ssh-keygen` to sign with `gpg.format ssh`: exactly that shape, under the namespace `git`, on a connection that was not forwarded.

Everything else goes to the card, where nobody answers and it fails in sixty seconds: any other app, Terminal included, anything forwarded, a signature over anything else, and a login to a server the pass has not seen, which is a stranger's or a new one. The rest of your vault is out of a pass's reach, and the vault stays shut under one.

This changes what a lock means: while a pass stands, the private half of every SSH key in the vault is in this app's memory with the vault shut. It is kept out of swap and is written to no disk. An ordinary lock leaves a pass running, or it would be no use. It ends at its time, at Revoke, at Lock and Forget, at Sign Out, when the agent's switch goes off, when the app quits and when the enrolled fingers change, and each of those overwrites every key with zeros. The change of fingers is noticed at the next request or lock screen.

What it gives up is this. Until it ends, whatever runs under that app has all of the above, unasked: every shell, build script and install hook it starts, and anything that has talked it into something. It can log in with any of your keys to any server in that file. It can make any commit or tag verify as yours, in any repository, and such a signature says nothing of where or when, and goes on verifying after the pass ends, for as long as the key is trusted. Nothing takes one back but dropping the key.

`known_hosts` is your file, so anything running as you could have written to it before you gave the pass. It is read once, as the pass is given, so what writes to it afterwards does not count, `ssh -o StrictHostKeyChecking=accept-new` among them. That catches a stranger and not a thief. A client older than OpenSSH 8.9 does not say when it forwards, so forwarding through one is not seen.

What is kept: the app is known by its code signature, never its name, so an app with no team of its own cannot hold a pass. Developer lists each pass with its commits and logins, the mark's menu has Revoke All, the lock screen says how many are running, and the first unlock after a signature says how many commits and logins, by which app. All of that is in memory and gone at a quit.

### Answering from your phone

While a pass stands, a phone can answer what the pass leaves to the card: a server it has not seen, anything forwarded, a signature that is neither a login nor a commit. The answer is carried by a relay app on the Mac and its phone app, which are not part of this repository; the app takes the relay by its code signature, and `PeerCheck.oriCode` names the one it takes. Add Phone in Settings, Developer, opens a socket for five minutes. The phone makes a key in its Secure Enclave that answers to Face ID, and a card on the Mac names the phone and a short fingerprint. Compare it with the phone's, because that is what stops anything in the middle from swapping the key, and give a finger. Only the public key is kept, in the app's settings. Forget Phone removes it, and so does Sign Out.

With a pass standing and a phone registered, `~/.oripass/approve.sock` is there, and it takes the relay's own signed process and nothing else. With either missing there is no file. When a card comes up for the app that holds the pass, for a key it holds, the words on the card cross to the relay, with the app, the key's name and fingerprint, the host and its key's fingerprint and an expiry. They go on to your phone, so the relay and whatever carries it can read them. No key crosses.

The card stays up and either the finger or the phone answers, and the wait is 120 seconds. A yes is a signature by the phone's key over those words and a number used once, and OriPass checks it itself, so the relay can lose or hold back an answer and cannot make one. Words changed on the way, an old answer sent again, or a request past its time are refused. A yes covers that one request. The pass signs it from what it holds, and the vault stays shut: nothing a phone says opens it, makes a server known, gives a pass or leaves an approval behind. So what it gives up is this: for a key a pass holds, your unlocked phone and your face now do from anywhere what only a finger at the Mac could. Developer and the line at the next unlock count these apart.

## Claude Code

`Plugins/claude-code/` lets a Claude Code session use OriPass's SSH agent, so that it runs plain `ssh` and you put a finger on the Mac. Until the agent is switched on the plugin finds nothing and changes nothing. From the top of this repository:

    claude plugin marketplace add ./Plugins/claude-code
    claude plugin install oripass@oripass

Claude Code reads the plugin from that folder and does not copy it, so install it from a checkout that stays where it is.

Each time a session starts or is resumed, the plugin looks for `~/.oripass/agent.sock`. If something is listening there it sets `SSH_AUTH_SOCK` to it for the commands that session runs, over whatever was set before. It connects to find that out and sends nothing, because a request over a locked vault would ask for your finger. With no socket, or a dead one, the session is left as it was. A skill tells the session to use plain `ssh`, `scp` and `git`, to say when a finger may be asked for and wait, and to stop and tell you on a refusal.

Nothing in the plugin reads your vault or asks for a key. It cannot stop `ssh` itself: after the agent's keys, `ssh` still tries the default key files in `~/.ssh`, as it always does.

## What it is not

It is not as closed as 1Password or as Bitwarden's desktop app. While your vault is unlocked, `bw` runs as a child process and holds it decrypted. The app speaks to that child over one connected socket the child is born holding. There is no socket file and no port, so no other program can connect to it and ask for your items. Nothing that opens the vault is in that child's environment or its arguments either: it is opened by your master password sent down that socket. `bw` answers with the session key it made, so the key passes through this app's memory. The app does not read it, keep it or write it anywhere. Signing in is the exception. `bw login` takes your master password from its environment, so for as long as a sign-in runs, a wait for a two-step code included, the password is in the environment of that `bw` and of the shell around it, where a program running as you can read it. That is when you sign in and not at each unlock. None of this puts the vault out of reach of a program running as you. The child is Homebrew's node, which is not a hardened process, so on a Mac with developer tools switched on a debugger run as you can attach to it and read its memory. 1Password and Bitwarden's desktop app keep the vault inside their own hardened process, and a program running as you has to break into that first. Another user on the Mac cannot reach any of this, and a web page cannot. Malware running under your account can, for as long as the vault is unlocked, and it can watch your keys while you type the password. The two files under `seal/` are your master password for whoever can make this Mac's enclave answer, which takes your finger. If that is not a line you will live with, do not use this app.

While your vault is unlocked the app keeps a socket file of its own, in its group container, as the door for its browser extension. Before it reads a byte, it asks macOS what connected and closes on anything that is not one of three helpers signed by the same team, and the file goes at the lock. One is the extension for Safari, which is inside the app, sandboxed, with the group as all it can reach outside its sandbox. It passes each message from the page's extension to the door and the answer back, and it holds neither. The second is the AutoFill provider, sandboxed the same way, which macOS starts when you pick OriPass from its Passwords menu. The third is a small program for Orion to start, which speaks only to that door and answers nothing but Orion. It gets through the door only while Let Orion reach OriPass is on. Orion does not hold an extension to the list in the file that names the program, so any extension in Orion can start it, and what stands in the way is the card: an extension you have not allowed gets no list and no password. The card trusts the origin Orion gives, so allow only what you installed. The SSH agent's socket is a second one, only with its switch on, and "The SSH agent" says who can reach it.

It does not make passkeys yet, and it does not suggest logins or one-time codes over the keyboard. OriPass is in the system's password AutoFill, switched on in System Settings › General › AutoFill & Passwords, but for a login only behind the Passwords menu, because a suggestion over a field needs usernames and sites written to a database of the system's, on disk and there while the vault is locked. It is there only in a build made with its two Developer ID provisioning profiles, which a free account cannot have. It lists logins only with the vault open. OriPass also has its own extension in Safari and Orion, any other browser keeps Bitwarden's, and everywhere else OriPass types the username, a Tab and the password as keys. With the caret already in a password field it types the password alone, and a login with no username is typed nowhere else, so that a password does not land in a field that shows it.

It has no tags. Bitwarden has none. If you came from 1Password, the import turned each item's first tag into its folder and dropped the others, and those folders are what the sidebar calls vaults. An item is in one or in none.

It has five kinds of item: logins, secure notes, credit cards, identities and SSH keys. A login that used to be a Wi-Fi router in 1Password is a login now, with the router's fields as custom fields under it. The same went for servers and API credentials, and licences, memberships and passports became identities or notes.

A copy from `make install` is notarised, under your own team. A Debug build is not: it is signed with a development certificate, Gatekeeper rejects it when asked (`spctl -a`), and it carries neither the Safari extension, which Safari would not run, nor the AutoFill provider, which macOS would not load.

It is not for Intel Macs, and not for macOS before 27.

It does not create an account, change your master password, set up two-step login, import or export. Bitwarden's web vault does those. An organisation's collections are shown and cannot be managed.

It does not update itself or tell you there is something newer. You pull and run `make install`.

It shows one-time codes on a free account, computed on your Mac from the secret that arrives in every item. Bitwarden sells that as part of Premium, and its own apps and `bw` refuse it without. Paying for Premium is the fair thing to do if you use them. Attachments go through `bw`, which refuses them without Premium. So does the archive: on a free account `bw` will not archive an item, and OriPass shows you its sentence.

## Where it stands

Version 0.1.0. Everything above was built and tested against an invented vault and a stand-in for `bw` that replays answers written by hand from Bitwarden's source. A script asked the real `bw` 2026.9.1 the questions the app asks that change nothing, on one account, then made a note and a login of its own there, edited them and deleted them, and the fixtures were corrected to what `bw` said. The installed app starts, finds `bw`, shows its lock screen and runs the whole invented vault through every surface without leaving a value on disk, in the log or on the pasteboard. What it does with a real login, a real sync, a real finger and a real key typed into another app's field has had less testing than that.

The extension has run in WebKit under tests far more than in either browser.

No control has been heard through VoiceOver. Each has a name, and that is all that can be said.

## Other people's work

OriPass itself is under the MIT licence (`LICENSE`).

`bw` is Bitwarden's, under the GPL 3.0, installed by Homebrew and not part of this app; its source was read for facts and none of it is copied here. The Public Suffix List under `Vendor/psl/`, and its copy in `Extension/`, is Mozilla's, under the MPL 2.0. EFF's long word list under `Vendor/eff/`, which the iPhone app makes passphrases from, is the Electronic Frontier Foundation's, under CC BY 3.0 US. The two-factor list comes from 2FA Directory by 2factorauth, under the MIT licence, and `Tests/Fixtures/2fa-totp-slice.json` is a slice of it, with its notice beside it. Breached passwords are looked up in Have I Been Pwned's Pwned Passwords API, by range, and `Tests/Fixtures/pwned-range-5BAA6.txt` is one answer from it. The strength estimate counts guesses the way zxcvbn (MIT) describes, over a word list of this repository's own; no code of zxcvbn's is in it.

The three-pane layout and the keyboard are in the manner of 1Password for Mac, and none of its artwork, its name or its sentences is used. OriPass is not made by, or endorsed by, Bitwarden, AgileBits or anyone else named here, and all other trademarks belong to their owners.

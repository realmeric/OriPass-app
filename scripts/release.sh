#!/bin/bash
# OP-61: build the app for real, check that it is what it claims to be, and
# only then put it in /Applications.
#
#   scripts/release.sh                build, sign and verify in $TMPDIR,
#                                     and keep nothing
#   scripts/release.sh install        and notarize it, and replace
#                                     /Applications/OriPass.app
#   scripts/release.sh check <app>    the checks alone, on a bundle already
#                                     built, launching nothing
#   scripts/release.sh notarize <app> what an install does to a bundle that
#                                     passed, sending it to Apple
#   scripts/release.sh ticket <app>   whether a bundle is stapled and
#                                     notarized, asking nobody
#
# Nothing is written to /Applications unless every check passes, and each
# check that fails says its own sentence and exits 1. An install needs
# OP_NOTARY_PROFILE, a profile made by `xcrun notarytool store-credentials`,
# and stops before the build without one: Safari runs nothing else with its
# developer setting off. OP_APP_PROFILE and OP_AUTOFILL_PROFILE are the paths
# of the Developer ID provisioning profiles for the app and for the provider.
# With both, the system's AutoFill is in the build, since it is a capability
# and macOS starts neither without one. With neither it is left out, and the
# app needs no profile. One without the other stops before the build. The
# last check starts the build, so an OriPass that
# is running is quit first: two of them would fight over the hot keys. It is
# started in an empty home directory, where nobody is signed in and there is
# no seal to raise a Touch ID sheet over, and has to say that its lock screen
# is up and leave no child behind it.
#
# After an install the copy in /Applications is started the way the Finder
# would start it, on the real account, and asked the same two things.
#
# The build is removed when the script ends, whichever way it ends. A run
# that failed leaves its logs beside where the build was.

set -u
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

NAME=OriPass
BUNDLE_ID=com.meric.oripass
ENTITLEMENT=com.apple.security.automation.apple-events
GROUPS_KEY=com.apple.security.application-groups
HELPER=oripass-bridge
HELPER_ID=com.meric.oripass.bridge
EXTENSION=OriPassSafari
EXTENSION_ID=com.meric.oripass.safari
EXTENSION_POINT=com.apple.Safari.web-extension
AUTOFILL=OriPassAutoFill
AUTOFILL_ID=com.meric.oripass.autofill
AUTOFILL_POINT=com.apple.authentication-services-credential-provider-ui
AUTOFILL_KEY=com.apple.developer.authentication-services.autofill-credential-provider
# What ties a signature to its profile. Apple says not to count on macOS
# finding the profile without them.
APP_ID_KEY=com.apple.application-identifier
TEAM_KEY=com.apple.developer.team-identifier
SANDBOX=com.apple.security.app-sandbox
# Paths, each copied into the bundle it is for before anything is signed. A
# build with neither has no provider.
APP_PROFILE=${OP_APP_PROFILE:-}
AUTOFILL_PROFILE=${OP_AUTOFILL_PROFILE:-}
PROFILE=embedded.provisionprofile
# The certificate Safari runs an extension from with no developer setting.
IDENTITY=${OP_IDENTITY:-Developer ID Application}
NOTARY=${OP_NOTARY_PROFILE:-}
# The certificate's organisational unit. An ad hoc signature has none, and
# macOS then knows the app by its hash, so every rebuild is a stranger to
# Accessibility and Automation. OP_TEAM, or the line in Team.xcconfig, which
# git ignores.
TEAM=${OP_TEAM:-$(sed -n 's/^OP_TEAM *= *//p' "$ROOT/Team.xcconfig" 2>/dev/null)}
[ -n "$TEAM" ] || { printf 'xx no team: set OP_TEAM, or write "OP_TEAM = <team id>" in Team.xcconfig\n' >&2; exit 1; }
GROUP=$TEAM.oripass
# Built outside the repo on purpose. The repo is under ~/Documents, which is
# in iCloud Drive, and the file provider stamps com.apple.FinderInfo on every
# bundle directory it sees as fast as it is cleared. codesign refuses a
# bundle that carries one.
OUT="${TMPDIR:-/tmp/}oripass-release"
INSTALLED="/Applications/$NAME.app"

say() { printf '== %s\n' "$*"; }
bad() { printf 'xx %s\n' "$*" >&2; exit 1; }

# The door lets Orion's host in by its name, its team and its hardened runtime
# (`PeerCheck`), and a release build turns away one with get-task-allow, so a
# helper short of any of these is one the installed app would not talk to.
check_helper() {
    local helper="$1/Contents/Helpers/$HELPER" found
    [ -x "$helper" ] || bad "the host for Orion is not in the bundle, at Contents/Helpers/$HELPER"

    found=$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$found" = "$HELPER_ID" ] || bad "the host is signed as ${found:-nothing}, and the door takes $HELPER_ID"

    found=$(codesign -d --verbose=2 "$helper" 2>&1 | grep -o 'flags=[^ ]*')
    case "$found" in
        *runtime*) ;;
        *) bad "the host's hardened runtime is off (${found:-no flags}), so anything could be loaded into what the door trusts" ;;
    esac

    found=$(codesign -d --entitlements - --xml "$helper" 2>/dev/null | plutil -p - 2>/dev/null \
        | sed -n 's/^ *"\(.*\)" => .*/\1/p' | tr '\n' ' ' | sed 's/ $//')
    [ "$found" = "$GROUPS_KEY" ] || bad "the host should carry $GROUPS_KEY alone and carries: ${found:-nothing}"
    codesign -d --entitlements - --xml "$helper" 2>/dev/null | plutil -p - | grep -q "0 => \"$GROUP\"" \
        || bad "the host's $GROUPS_KEY does not name $GROUP, where the door stands"

    found=$(codesign -dv "$helper" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$found" = "$TEAM" ] || bad "the host's team is ${found:-missing}, and $TEAM was expected: the door would close on it"
}

# Safari's way to the door. It is not loaded unless it is sandboxed, the door
# takes it by its name, its team and its hardened runtime, and a sandbox that
# does not name the group has no way to the door's file. All of Extension/ has
# to lie where the manifest says, at the top of Resources.
check_extension() {
    local appex="$1/Contents/PlugIns/$EXTENSION.appex" plist found
    plist="$appex/Contents/Info.plist"
    [ -f "$plist" ] || bad "Safari's extension is not in the bundle, at Contents/PlugIns/$EXTENSION.appex"

    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null)
    [ "$found" = "$EXTENSION_POINT" ] || bad "the extension's point is ${found:-missing}, and Safari looks under $EXTENSION_POINT"
    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$plist" 2>/dev/null)
    [ "$found" = "$EXTENSION.SafariWebExtensionHandler" ] \
        || bad "the extension's class is ${found:-missing}, and $EXTENSION.SafariWebExtensionHandler is what it holds"
    [ -f "$appex/Contents/Resources/manifest.json" ] && [ -f "$appex/Contents/Resources/icons/16.png" ] \
        || bad "the extension's manifest and icons are not at the top of its Resources"

    found=$(codesign -dv "$appex" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$found" = "$EXTENSION_ID" ] || bad "the extension is signed as ${found:-nothing}, and the door takes $EXTENSION_ID"

    found=$(codesign -d --verbose=2 "$appex" 2>&1 | grep -o 'flags=[^ ]*')
    case "$found" in
        *runtime*) ;;
        *) bad "the extension's hardened runtime is off (${found:-no flags}), so the door would close on it" ;;
    esac

    found=$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -p - 2>/dev/null \
        | sed -n 's/^ *"\(.*\)" => .*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$found" = "$SANDBOX $GROUPS_KEY" ] \
        || bad "the extension should carry $SANDBOX and $GROUPS_KEY alone and carries: ${found:-nothing}"
    codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -p - | grep -q "\"$SANDBOX\" => true" \
        || bad "the extension's sandbox is there and is not on, and Safari would not load it"
    codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -p - | grep -q "0 => \"$GROUP\"" \
        || bad "the extension's $GROUPS_KEY does not name $GROUP, where the door stands"

    found=$(codesign -dv "$appex" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$found" = "$TEAM" ] || bad "the extension's team is ${found:-missing}, and $TEAM was expected: the door would close on it"
}

# A provisioning profile, for the code it is about to authorise: its App ID,
# the capability, a Developer ID one and in date. A signature it does not cover
# is one macOS will not start, and says so nowhere a person is looking.
check_profile() {
    local profile=$1 id=$2 who=$3 plist decoded found
    # Not `security cms -D`, which adds the certificates it finds to the
    # default keychain. The signature is macOS's to judge, at launch.
    plist=$(/usr/bin/openssl smime -verify -noverify -inform DER -in "$profile" 2>/dev/null)
    decoded=$(printf '%s' "$plist" | plutil -p - 2>/dev/null)
    [ -n "$decoded" ] || bad "$who's provisioning profile does not read as one: $profile"
    printf '%s\n' "$decoded" | grep -q "\"$APP_ID_KEY\" => \"$TEAM\.$id\"" \
        || bad "$who's provisioning profile is not for $TEAM.$id"
    printf '%s\n' "$decoded" | grep -q "\"$AUTOFILL_KEY\" => true" \
        || bad "$who's provisioning profile does not hold the AutoFill capability, $AUTOFILL_KEY"
    printf '%s\n' "$decoded" | grep -q '"ProvisionsAllDevices" => true' \
        || bad "$who's provisioning profile is not a Developer ID one, and would stop at the devices it names"
    found=$(printf '%s' "$plist" | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
    [[ "$found" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || bad "$who's provisioning profile ran out on ${found:-no date}"
}

# The system's way to the door. It is not loaded unless it is sandboxed and
# holds the capability, the door takes it as it takes Safari's, and it answers
# with passwords and passkeys and writes to no list of identities (D6).
check_autofill() {
    local appex="$1/Contents/PlugIns/$AUTOFILL.appex" plist found
    plist="$appex/Contents/Info.plist"
    [ -f "$plist" ] || bad "the AutoFill provider has no Info.plist, at Contents/PlugIns/$AUTOFILL.appex"

    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null)
    [ "$found" = "$AUTOFILL_POINT" ] || bad "the provider's point is ${found:-missing}, and the system looks under $AUTOFILL_POINT"
    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$plist" 2>/dev/null)
    [ "$found" = "$AUTOFILL.CredentialProviderViewController" ] \
        || bad "the provider's class is ${found:-missing}, and $AUTOFILL.CredentialProviderViewController is what it holds"
    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:ASCredentialProviderExtensionCapabilities:ProvidesPasskeys' "$plist" 2>/dev/null)
    [ "$found" = "true" ] || bad "the provider's ProvidesPasskeys is ${found:-missing}, and the system would offer it no passkey"
    found=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:ASCredentialProviderExtensionCapabilities:ProvidesOneTimeCodes' "$plist" 2>/dev/null)
    [ "$found" = "true" ] || bad "the provider's ProvidesOneTimeCodes is ${found:-missing}, and the system would offer it no code field"

    found=$(codesign -dv "$appex" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$found" = "$AUTOFILL_ID" ] || bad "the provider is signed as ${found:-nothing}, and the door takes $AUTOFILL_ID"

    found=$(codesign -d --verbose=2 "$appex" 2>&1 | grep -o 'flags=[^ ]*')
    case "$found" in
        *runtime*) ;;
        *) bad "the provider's hardened runtime is off (${found:-no flags}), so the door would close on it" ;;
    esac

    found=$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -p - 2>/dev/null \
        | sed -n 's/^ *"\(.*\)" => .*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$found" = "$APP_ID_KEY $AUTOFILL_KEY $TEAM_KEY $SANDBOX $GROUPS_KEY" ] \
        || bad "the provider should carry $AUTOFILL_KEY, $SANDBOX, $GROUPS_KEY and its App ID and team alone and carries: ${found:-nothing}"
    found=$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -p -)
    printf '%s\n' "$found" | grep -q "\"$AUTOFILL_KEY\" => true" \
        || bad "the provider's $AUTOFILL_KEY is there and is not true"
    printf '%s\n' "$found" | grep -q "\"$SANDBOX\" => true" \
        || bad "the provider's sandbox is there and is not on, and the system would not load it"
    printf '%s\n' "$found" | grep -q "0 => \"$GROUP\"" \
        || bad "the provider's $GROUPS_KEY does not name $GROUP, where the door stands"
    printf '%s\n' "$found" | grep -q "\"$APP_ID_KEY\" => \"$TEAM\.$AUTOFILL_ID\"" \
        || bad "the provider's $APP_ID_KEY is not $TEAM.$AUTOFILL_ID"
    printf '%s\n' "$found" | grep -q "\"$TEAM_KEY\" => \"$TEAM\"" \
        || bad "the provider's $TEAM_KEY is not $TEAM"

    found=$(codesign -dv "$appex" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$found" = "$TEAM" ] || bad "the provider's team is ${found:-missing}, and $TEAM was expected: the door would close on it"

    [ -f "$appex/Contents/$PROFILE" ] || bad "the provider has no provisioning profile, at Contents/$PROFILE, and nothing would load it"
    check_profile "$appex/Contents/$PROFILE" "$AUTOFILL_ID" "the provider"
}

# What a bundle is, read from the bundle and from its signature. Nothing is
# run.
check() {
    local app=$1 plist="$1/Contents/Info.plist" found provider= others="$HELPER_ID and $EXTENSION_ID"
    [ -f "$plist" ] || bad "no Info.plist in $app"
    # A build without the profiles has no provider, and is held to that.
    [ -d "$app/Contents/PlugIns/$AUTOFILL.appex" ] && provider=yes

    found=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)
    [ "$found" = "$BUNDLE_ID" ] || bad "the bundle id is ${found:-missing}, and $BUNDLE_ID was expected"

    # The build merges the icon's two keys into the plist, so they are read
    # from the bundle and not from Sources/Info.plist.
    found=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" 2>/dev/null)
    [ "$found" = AppIcon ] && [ -e "$app/Contents/Resources/Assets.car" ] \
        && [ "$(head -c 4 "$app/Contents/Resources/AppIcon.icns" 2>/dev/null)" = icns ] \
        || bad "the icon is missing: the bundle needs AppIcon.icns, Assets.car and CFBundleIconFile"

    [ -s "$app/Contents/Resources/public_suffix_list.dat" ] \
        || bad "the Public Suffix List is not in the bundle, and without it no login is suggested for a page"

    [ -z "$(ls "$app/Contents/MacOS" | grep -v "^$NAME\$")" ] \
        || bad "Contents/MacOS holds more than the app, which is how a Debug build looks: $(ls "$app/Contents/MacOS" | grep -v "^$NAME\$" | tr '\n' ' ')"

    codesign --verify --deep --strict "$app" 2>/dev/null \
        || bad "the signature does not verify: $(codesign --verify --deep --strict "$app" 2>&1 | tail -1)"

    found=$(codesign -d --verbose=2 "$app" 2>&1 | grep -o 'flags=[^ ]*')
    case "$found" in
        *runtime*) ;;
        *) bad "the hardened runtime is off (${found:-no flags})" ;;
    esac

    # The entitlements as the signature carries them, one key to a line.
    found=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>/dev/null \
        | sed -n 's/^ *"\(.*\)" => .*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')
    case " $found " in
        *" com.apple.security.get-task-allow "*)
            bad "the signature carries get-task-allow, so any process of his could attach to it and read the vault" ;;
    esac
    [ -n "$found" ] || bad "the signature carries no entitlement, and $ENTITLEMENT is the one a browser's tab is asked with"
    if [ -n "$provider" ]; then
        [ "$found" = "$APP_ID_KEY $AUTOFILL_KEY $TEAM_KEY $GROUPS_KEY $ENTITLEMENT" ] \
            || bad "the signature should carry $AUTOFILL_KEY, $GROUPS_KEY, $ENTITLEMENT and its App ID and team alone and carries: $found"
    else
        [ "$found" = "$GROUPS_KEY $ENTITLEMENT" ] || bad "the signature should carry $GROUPS_KEY and $ENTITLEMENT alone and carries: $found"
    fi
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -q "\"$ENTITLEMENT\" => true" \
        || bad "$ENTITLEMENT is there and is not true"
    # The door's file is in this group, and the app must be able to reach it.
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -q "0 => \"$GROUP\"" \
        || bad "$GROUPS_KEY does not name $GROUP, where the door for the browser stands"
    if [ -n "$provider" ]; then
        codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -q "\"$AUTOFILL_KEY\" => true" \
            || bad "$AUTOFILL_KEY is there and is not true"
        codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -q "\"$APP_ID_KEY\" => \"$TEAM\.$BUNDLE_ID\"" \
            || bad "$APP_ID_KEY is not $TEAM.$BUNDLE_ID"
        codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -q "\"$TEAM_KEY\" => \"$TEAM\"" \
            || bad "$TEAM_KEY is not $TEAM"
    fi

    found=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$found" = "$TEAM" ] \
        || bad "the signature's team is ${found:-missing}, and $TEAM was expected: macOS would take every rebuild for another app and ask for Accessibility again"

    if [ -n "$provider" ]; then
        [ -f "$app/Contents/$PROFILE" ] || bad "the app has no provisioning profile, at Contents/$PROFILE, and macOS would not start it"
        check_profile "$app/Contents/$PROFILE" "$BUNDLE_ID" "the app"
        others="$HELPER_ID, $EXTENSION_ID and $AUTOFILL_ID"
    else
        [ ! -e "$app/Contents/$PROFILE" ] || bad "the app holds a provisioning profile and no AutoFill provider, at Contents/$PROFILE"
    fi

    check_helper "$app"
    check_extension "$app"
    [ -z "$provider" ] || check_autofill "$app"

    say "$NAME $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") verified: $BUNDLE_ID, the icon, hardened, its entitlements, team $TEAM, and $others the same"
}

# Whether the system takes an extension from this bundle. Named for as long
# as it is asked and no longer, so a build in $TMPDIR is not left for it.
listed() {
    local appex="$1/Contents/PlugIns/$2.appex" found
    pluginkit -a "$appex" 2>/dev/null
    found=$(pluginkit -m -A -D -v -p "$3" 2>/dev/null | grep -F "$appex")
    pluginkit -r "$appex" 2>/dev/null
    [ -n "$found" ] || bad "pluginkit does not list $2 from the build, so the system would not find it"
    say "pluginkit lists $2 from the build"
}

# A ticket in the bundle, which Gatekeeper reads with no network, and
# Gatekeeper's own word. Both are local, and neither says anything about a
# build that was never sent.
ticket() {
    local app=$1
    xcrun stapler validate "$app" >/dev/null 2>&1 || bad "no ticket is stapled to $app"
    spctl --assess --type execute "$app" 2>/dev/null \
        || bad "Gatekeeper does not take $app: $(spctl --assess --type execute "$app" 2>&1 | tail -1)"
    say "stapled, and Gatekeeper takes it as notarized"
}

# Sends the whole bundle to Apple and waits for its answer, which can be some
# minutes. The answer is read from what notarytool prints and not from how it
# exits, and a build Apple turned down gets no ticket and goes no further.
notarize() {
    local app=$1 answer status id
    [ -n "$NOTARY" ] || bad "notarizing needs OP_NOTARY_PROFILE, the name given to xcrun notarytool store-credentials"
    say "sending the build to Apple, under the profile $NOTARY"
    ditto -c -k --keepParent "$app" "$OUT.zip" || bad "could not zip $app for Apple"
    answer=$(xcrun notarytool submit "$OUT.zip" --keychain-profile "$NOTARY" --wait --output-format json 2>/dev/null)
    rm -f "$OUT.zip"
    status=$(printf '%s' "$answer" | plutil -extract status raw -o - - 2>/dev/null)
    id=$(printf '%s' "$answer" | plutil -extract id raw -o - - 2>/dev/null)
    [ -n "$id" ] || bad "Apple gave no answer: is $NOTARY a profile on this Mac, and is it online?"
    [ "$status" = Accepted ] \
        || bad "Apple said ${status:-nothing} of the build; xcrun notarytool log $id --keychain-profile $NOTARY has why"
    xcrun stapler staple "$app" >/dev/null 2>&1 || bad "Apple accepted the build and its ticket would not staple"
    ticket "$app"
}

# The line the app writes once its window holds the lock screen or the
# panes (`AppDelegate`), waited for in the log of one process.
door_line() {
    local pid=$1 line=
    for _ in $(seq 1 15); do
        kill -0 "$pid" 2>/dev/null || return 1
        line=$(/usr/bin/log show --last 2m --style compact \
            --predicate "subsystem == \"$BUNDLE_ID\" AND processID == $pid AND eventMessage BEGINSWITH \"door: \"" \
            2>/dev/null | grep -o 'door: .*' | tail -1)
        [ -n "$line" ] && break
        sleep 1
    done
    printf '%s' "$line"
}

# Whether a running copy shows the lock screen and has started nothing.
locked_and_alone() {
    local pid=$1 where=$2 line children
    line=$(door_line "$pid") || bad "$where quit before it showed a window"
    [ "$line" = "door: lock screen up, window on screen" ] \
        || bad "$where did not show the lock screen (${line:-it said nothing in fifteen seconds})"
    children=$(pgrep -P "$pid" | tr "\n" " " | sed "s| $||")
    [ -z "$children" ] || bad "$where is locked and has a child running behind it (pid $children)"
}

starts() {
    local app=$1 home pid
    if pgrep -xq "$NAME"; then
        say "quitting the $NAME that is running"
        pkill -x "$NAME"
        sleep 1
    fi
    home=$(mktemp -d "${TMPDIR:-/tmp/}oripass-first.XXXXXX")
    CFFIXED_USER_HOME="$home" HOME="$home" "$app/Contents/MacOS/$NAME" >/dev/null 2>&1 &
    pid=$!
    disown "$pid"
    STARTED=$pid STARTED_HOME=$home
    locked_and_alone "$pid" "the build"
    kill "$pid" 2>/dev/null
    rm -rf "$home"
    STARTED= STARTED_HOME=
    say "it starts, shows the lock screen and has no child while locked"
}

if [ "${1:-}" = check ]; then
    [ -d "${2:-}" ] || bad "check takes the path of an app"
    check "$2"
    exit 0
fi
if [ "${1:-}" = ticket ]; then
    [ -d "${2:-}" ] || bad "ticket takes the path of an app"
    ticket "$2"
    exit 0
fi
if [ "${1:-}" = notarize ]; then
    [ -d "${2:-}" ] || bad "notarize takes the path of an app"
    notarize "$2"
    exit 0
fi
WHAT=${1:-}
[ -z "$WHAT" ] || [ "$WHAT" = install ] || bad "release.sh takes install, check <app>, notarize <app>, ticket <app> or nothing"
# Before the build, which would take minutes to arrive at the same sentence.
# Both of these quit the running app, and a pass dies with it.
"$ROOT/scripts/passes.sh" || bad "nothing was built"
[ "$WHAT" != install ] || [ -n "$NOTARY" ] \
    || bad "make install needs OP_NOTARY_PROFILE, the name given to xcrun notarytool store-credentials; nothing was built or installed"
PROVIDER=
if [ -n "$APP_PROFILE$AUTOFILL_PROFILE" ]; then
    [ -f "$APP_PROFILE" ] && [ -f "$AUTOFILL_PROFILE" ] \
        || bad "the system's AutoFill needs both OP_APP_PROFILE and OP_AUTOFILL_PROFILE, each the path of a Developer ID provisioning profile; nothing was built"
    check_profile "$APP_PROFILE" "$BUNDLE_ID" "the app"
    check_profile "$AUTOFILL_PROFILE" "$AUTOFILL_ID" "the provider"
    PROVIDER=yes
else
    say "no provisioning profiles, so this build leaves the system's AutoFill out"
fi

cd "$ROOT"
APP="$OUT/$NAME.app"

# The build is a signed copy of the app, its symbols and two logs, and
# nothing reads any of them once the script has ended: what was installed is
# in /Applications. So it all goes, however the script ends. After a failure
# the logs stay, since the sentence that failed may have named one.
STARTED= STARTED_HOME=
tidy() {
    local status=$?
    [ -z "$STARTED" ] || kill "$STARTED" 2>/dev/null
    [ -z "$STARTED_HOME" ] || rm -rf "$STARTED_HOME"
    rm -rf "$OUT" "$OUT".*.entitlements
    [ "$status" = 0 ] && rm -f "$OUT.log" "$OUT.sign.log"
    exit "$status"
}
trap tidy EXIT
trap 'exit 130' INT TERM

say "generating the project"
xcodegen generate >/dev/null || bad "xcodegen failed"

say "building Release into $OUT"
rm -rf "$OUT"
# Built unsigned and signed below by hand: Xcode signs at the end of its own
# build, before anything can take an attribute off a file.
xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    CONFIGURATION_BUILD_DIR="$OUT" CODE_SIGNING_ALLOWED=NO OP_TEAM="$TEAM" \
    build > "$OUT.log" 2>&1 || bad "the build failed; $OUT.log has why"
[ -d "$APP" ] || bad "no $NAME.app came out of the build"

say "signing"
# Every file and every directory: `xattr -cr` misses a bundle directory's
# own attributes.
find "$APP" -exec xattr -c {} \; 2>/dev/null
LEFT=$(find "$APP" -exec xattr -l {} \; 2>/dev/null | grep -c FinderInfo)
[ "$LEFT" = 0 ] || bad "$LEFT files still carry Finder information, which codesign refuses"
# Inside out, the extensions and the host before the app, since the app's
# signature seals what is inside it, and each profile before the code it is
# for. Notarization wants a secure timestamp on each, so signing needs the
# network. The provider is built either way and goes here without its profile.
# The entitlements name the team as Xcode would write it, $(DEVELOPMENT_TEAM),
# which codesign does not read, so each is signed from a copy with the team in.
team_in() {
    sed "s/\$(DEVELOPMENT_TEAM)/$TEAM/g" "$1" > "$OUT.$(basename "$1")" || bad "$1 would not copy"
    printf '%s' "$OUT.$(basename "$1")"
}
APP_ENTITLEMENTS=$(team_in "$ROOT/$NAME.entitlements")
if [ -n "$PROVIDER" ]; then
    APP_ENTITLEMENTS=$(team_in "$ROOT/AutoFill/$NAME.release.entitlements")
    cp "$APP_PROFILE" "$APP/Contents/$PROFILE" && cp "$AUTOFILL_PROFILE" "$APP/Contents/PlugIns/$AUTOFILL.appex/Contents/$PROFILE" \
        || bad "the profiles would not copy into the bundle"
else
    rm -rf "$APP/Contents/PlugIns/$AUTOFILL.appex"
fi
codesign --force --options runtime --timestamp --entitlements "$(team_in "$ROOT/Safari/$EXTENSION.entitlements")" \
    --sign "$IDENTITY" "$APP/Contents/PlugIns/$EXTENSION.appex" > "$OUT.sign.log" 2>&1 \
    || bad "the extension would not sign: $(tail -1 "$OUT.sign.log")"
if [ -n "$PROVIDER" ]; then
    codesign --force --options runtime --timestamp --entitlements "$(team_in "$ROOT/AutoFill/$AUTOFILL.entitlements")" \
        --sign "$IDENTITY" "$APP/Contents/PlugIns/$AUTOFILL.appex" >> "$OUT.sign.log" 2>&1 \
        || bad "the provider would not sign: $(tail -1 "$OUT.sign.log")"
fi
codesign --force --options runtime --timestamp --entitlements "$(team_in "$ROOT/Helper/$HELPER.entitlements")" \
    --identifier "$HELPER_ID" --sign "$IDENTITY" "$APP/Contents/Helpers/$HELPER" >> "$OUT.sign.log" 2>&1 \
    || bad "the host would not sign: $(tail -1 "$OUT.sign.log")"
codesign --force --options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP" >> "$OUT.sign.log" 2>&1 || bad "the app would not sign: $(tail -1 "$OUT.sign.log")"

check "$APP"
listed "$APP" "$EXTENSION" "$EXTENSION_POINT"
[ -z "$PROVIDER" ] || listed "$APP" "$AUTOFILL" "$AUTOFILL_POINT"
starts "$APP"
say "built, signed and verified"

[ "$WHAT" = install ] || exit 0

notarize "$APP"

# What macOS knows an app by when it keeps a grant: the bundle id and the
# certificate, which is the designated requirement, and not the path or the
# hash. A copy that answers to the same one inherits what the last was given.
requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
if [ -d "$INSTALLED" ]; then
    if [ "$(requirement "$INSTALLED")" = "$(requirement "$APP")" ]; then
        say "the copy it replaces has the same designated requirement, so its grants are this one's"
    else
        say "the copy it replaces was signed as something else: macOS will ask for Accessibility and for each browser again"
    fi
fi

say "replacing $INSTALLED"
pkill -x "$NAME" 2>/dev/null && sleep 1
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED" || bad "could not copy the app to /Applications"
# The copy is checked where it lies, since that is the one he will run.
codesign --verify --deep --strict "$INSTALLED" 2>/dev/null || bad "the copy in /Applications does not verify"
ticket "$INSTALLED"
# Launch Services is told, or the registration of the old copy lingers and a
# login item points at a bundle that is gone.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALLED" >/dev/null 2>&1
# Started by Launch Services and not from this shell, so that the app and not
# the terminal is who macOS holds responsible for a key it posts.
open "$INSTALLED" || bad "the installed app would not open"
PID=
for _ in $(seq 1 10); do
    PID=$(pgrep -xn "$NAME") && break
    sleep 0.5
done
[ -n "$PID" ] || bad "the installed app is not running"
locked_and_alone "$PID" "the installed app"
say "installed, and running from /Applications behind its lock screen"

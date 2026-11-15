#!/bin/zsh
# PH-21, PH-26 and PH-29 end to end: a sign-in, the writes EditUITests and
# TypesUITests make and the passkey PasskeyUITests makes in Safari, against a
# stand-in that keeps them, and Bitwarden's own CLI reading what they made
# (with ssh-keygen for the new key).
# Run from the repo root with the UI tests built.
set -u
sim="OriPass iPhone 17"
saved=/tmp/oripass-saved.json
rm -f "$saved"
Phone/scripts/install-built.sh "$sim"
xcrun simctl spawn "$sim" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn "$sim" notifyutil -p com.apple.BiometricKit.enrollmentChanged
(cd Phone && python3 -I scripts/standin.py --port 8099 --save "$saved" > /tmp/oripass-standin.log 2>&1) & standin=$!
( while true; do sleep 2; xcrun simctl spawn "$sim" notifyutil -p com.apple.BiometricKit_Sim.pearl.match; done ) & matcher=$!
trap 'kill $standin $matcher 2>/dev/null' EXIT
for test in SignInUITests/testSigningInToTheStandIn EditUITests TypesUITests AutoFillUITests/testTurnOnOriPass PasskeyUITests; do
  echo "$test"
  xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -configuration Debug \
    -destination "platform=iOS Simulator,name=$sim" test-without-building -only-testing:"OriPassUITests/$test" 2>&1 \
    | grep -E "Executed .* tests?, with|error:" | grep -v '^\s*|' | sort -u | head -2
done
(cd Phone && scripts/bw-reads-edits.sh "$saved" 2>/dev/null)
(cd Phone && scripts/bw-reads-types.sh "$saved" 2>/dev/null)

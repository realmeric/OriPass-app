#!/bin/zsh
# AutoFill on the simulator: a face enrolled, a sign-in, AutoFill switched on
# for OriPass in Settings, then each AutoFill test named, with Face ID's
# match sent every two seconds while they run. VAULT names the stand-in's
# account; a test named ...Password... runs with debug-no-face in the App
# Group, so that the extension asks for the master password. Run from the
# repo root.
#   Phone/scripts/autofill-ui.sh AutoFillUITests/testTheSuggestionIsThereWhileLocked ...
set -u
sim="OriPass iPhone 17"
notify() { xcrun simctl spawn "$sim" notifyutil "$@"; }
run() {
  xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -configuration Debug \
    -destination "platform=iOS Simulator,name=$sim" -resultBundlePath "/tmp/oripass-autofill-${1//\//-}.xcresult" \
    test-without-building -only-testing:"OriPassUITests/$1" 2>&1 \
    | grep -E "Executed .* tests?, with|error:" | grep -v '^\s*|' | sort -u | head -3
}
rm -rf /tmp/oripass-autofill-*.xcresult(N)
xcrun simctl boot "$sim" 2>/dev/null
Phone/scripts/install-built.sh "$sim"
notify -s com.apple.BiometricKit.enrollmentChanged 1; notify -p com.apple.BiometricKit.enrollmentChanged
(cd Phone && python3 -I scripts/standin.py --port 8099 --vault "${VAULT:-Tests/Fixtures/vault.json}" > /tmp/oripass-standin.log 2>&1) & standin=$!
( while true; do sleep 2; notify -p com.apple.BiometricKit_Sim.pearl.match; done ) & matcher=$!
trap 'kill $standin $matcher 2>/dev/null' EXIT
echo "sign in"; run SignInUITests/testSigningInToTheStandIn
echo "turn on"; run AutoFillUITests/testTurnOnOriPass
group=$(xcrun simctl get_app_container "$sim" com.meric.oripass.ios group.com.meric.oripass)
for test in "$@"; do
  if [[ $test == *Password* ]]; then touch "$group/debug-no-face"; else rm -f "$group/debug-no-face"; fi
  echo "$test"; run "$test"
done
rm -f "$group/debug-no-face"
[[ -f "$group/trace.log" ]] && grep -E "memory|filled|on screen|in grace" "$group/trace.log" | tail -8

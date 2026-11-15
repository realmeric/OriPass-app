#!/bin/zsh
# PH-7 on the simulator: a face enrolled, a sign-in, the app opened again by
# that face with no password, then locked and opened by the password. A
# changed enrolment cannot be shown here: the simulator's face has one mark
# whatever is enrolled, so FaceKeyTests stands for it. Run from the repo root with the project generated.
set -u
sim="OriPass iPhone 17"
notify() { xcrun simctl spawn "$sim" notifyutil "$@"; }
run() {
  xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -configuration Debug \
    -destination "platform=iOS Simulator,name=$sim" test-without-building -only-testing:"OriPassUITests/$1" 2>&1 \
    | grep -E "Executed .* tests?, with|error:" | grep -v '^\s*|' | head -3
}
xcrun simctl boot "$sim" 2>/dev/null
Phone/scripts/install-built.sh "$sim"
notify -s com.apple.BiometricKit.enrollmentChanged 1; notify -p com.apple.BiometricKit.enrollmentChanged
(cd Phone && python3 -I scripts/standin.py --port 8099 > /tmp/oripass-standin.log 2>&1) & standin=$!
trap 'kill $standin $matcher 2>/dev/null' EXIT
matcher=0
echo "sign in"; run SignInUITests/testSigningInToTheStandIn
( while true; do sleep 2; notify -p com.apple.BiometricKit_Sim.pearl.match; done ) & matcher=$!
echo "a face"; run FaceUITests/testAFaceOpensTheVault
echo "the password"; run FaceUITests/testThePasswordOpensItToo

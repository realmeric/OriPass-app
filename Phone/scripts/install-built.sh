#!/bin/zsh
# Puts the app the last build made on the simulator. A UI test run with
# test-without-building leaves an older copy in place, and with it an older
# AutoFill extension. Run from the repo root.
sim="${1:-OriPass iPhone 17}"
app=$(xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPass -destination "platform=iOS Simulator,name=$sim" \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/OriPass.app
xcrun simctl install "$sim" "$app"
xcrun simctl install "$sim" "${app:h}/OriPassForms.app"

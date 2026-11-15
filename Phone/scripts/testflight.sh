#!/bin/zsh
# A Release build of the phone app to TestFlight, for internal testing only:
# archived in $TMPDIR (a bundle in iCloud Drive cannot be signed), signed by
# the team in Phone/Team.xcconfig through the Apple account Xcode is signed
# in with, numbered by the clock, and uploaded to App Store Connect.
# Run from the repo root with the project generated. With --upload-only it
# sends the last archive again, for when App Store Connect refused it.
set -eu
test -f Phone/Team.xcconfig || { echo "Phone/Team.xcconfig is missing: see Phone/README.md."; exit 1; }
team=$(awk -F' = ' '/DEVELOPMENT_TEAM/ {print $2}' Phone/Team.xcconfig)
build=$(date +%Y%m%d%H%M)
work="${TMPDIR:-/tmp}/oripass-testflight"
mkdir -p "$work"
cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
if [[ "${1:-}" != --upload-only ]]; then
echo "archiving build $build"
rm -rf "$work/OriPass.xcarchive"
xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPass -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/OriPass.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$build archive -quiet
fi
echo "uploading"
xcodebuild -exportArchive -archivePath "$work/OriPass.xcarchive" -exportOptionsPlist "$work/export.plist" \
  -exportPath "$work/export" -allowProvisioningUpdates
echo "uploaded"

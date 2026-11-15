export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

PROJECT := OriPass.xcodeproj
SCHEME  := OriPass
DEST    := platform=macOS,arch=arm64
# The team comes from Team.xcconfig, which git ignores, or OP_TEAM in the
# environment, which wins (README, "Building it yourself").
XCB     := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -configuration Debug \
	$(if $(OP_TEAM),OP_TEAM=$(OP_TEAM))

.PHONY: gen build test run icon shots contrast contract canary canary-installed release install extension clean \
	phone-gen phone-build phone-test phone-run phone-device phone-bw-check phone-ui phone-face phone-autofill phone-edits phone-testflight

gen:
	xcodegen generate

# Xcode adds get-task-allow to every Debug signature unless told not to. The
# test run needs it, to load the test bundle into a hardened app. The app that
# is run, shot and searched for canaries is built without it, so it carries
# the one entitlement in OriPass.entitlements and nothing else.
build: gen
	$(XCB) build CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

test: gen
	$(XCB) test

# The old copy is killed first, so the window on screen is the one just built.
# `OP_DEMO=1 make run` reaches the app: `open` would not pass it on.
run: build
	@APP=$$($(XCB) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/OriPass.app; \
	scripts/passes.sh || exit 1; \
	pkill -x OriPass || true; \
	"$$APP/Contents/MacOS/OriPass" >/dev/null 2>&1 &

# The icon, drawn again into every size of the asset catalogue. Run when the
# mark changes, and commit what it wrote.
icon:
	swift scripts/make-icon.swift

# Every registered surface, from the demo vault, in light and in dark. Each
# file is written over the last one, and the app then removes what it did not
# write, so a surface that is no longer drawn leaves no shot of what it used
# to look like. Nothing is removed first: shots/ is in iCloud Drive, which
# keeps a file that was deleted and made again as "report 2.json". The icon
# the bundle carries is drawn beside them at 16, 32 and 512 points.
shots: build
	@APP=$$($(XCB) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/OriPass.app; \
	OP_DEMO=shots OP_SHOTS_DIR="$(CURDIR)/shots" "$$APP/Contents/MacOS/OriPass"

# Every colour words are drawn in against every ground they are drawn on, in
# light and in dark, from Palette.readings. Fails on one under 4.5 to 1.
contrast: build
	@APP=$$($(XCB) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/OriPass.app; \
	OP_DEMO=contrast "$$APP/Contents/MacOS/OriPass"

# After Homebrew upgrades bw: do its answers still have the shapes the
# fixtures hold? Run by hand, against a real account; asks for the
# master password on the terminal. Prints keys and never values.
contract:
	scripts/contract.sh

# D6, searched for. The second half of the definition of done.
canary: build
	scripts/canary.sh

# The canary again, over the copy in /Applications: the Release build, as it
# was signed and installed. The tour is the demo vault, whichever build.
canary-installed:
	OP_APP=/Applications/OriPass.app scripts/canary.sh

# A Release build made in $$TMPDIR, signed by hand and held to every check
# in scripts/release.sh. `make install` then replaces /Applications/OriPass.app
# and starts it from there; nothing is replaced when a check fails. With
# OP_APP_PROFILE and OP_AUTOFILL_PROFILE the system's AutoFill is in the build.
release:
	scripts/release.sh

install:
	scripts/release.sh install

# Extension/ with manifest.json at the top of a zip, for a browser that will
# not take the .appex. Orion's help does not say what it takes from disk.
EXTENSION_ZIP ?= build/OriPass-extension.zip
extension:
	@mkdir -p "$(dir $(abspath $(EXTENSION_ZIP)))"
	@rm -f "$(abspath $(EXTENSION_ZIP))"
	@cd Extension && zip -q -X -r "$(abspath $(EXTENSION_ZIP))" . -x '.*'
	@echo "$(EXTENSION_ZIP)"

clean:
	rm -rf build DerivedData $(PROJECT) Phone/OriPassPhone.xcodeproj

# The iPhone app (Phone/README.md). The simulator is one of its own, so a run
# leaves every other simulator on this Mac as it was.
PHONE_SIM  := OriPass iPhone 17
PHONE_XCB  := xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPass -configuration Debug
PHONE_DEST := platform=iOS Simulator,name=$(PHONE_SIM)

phone-gen:
	cd Phone && xcodegen generate --quiet

phone-build: phone-gen
	$(PHONE_XCB) -destination '$(PHONE_DEST)' build -quiet

# What xcodebuild says is cut to the failures and the count of tests run.
# SignOutTests empties the simulator's App Group as a sign-out would, so the
# UI runs after it sign in again first.
phone-test: SHELL := /bin/bash
phone-test: phone-gen
	set -o pipefail; $(PHONE_XCB) -destination '$(PHONE_DEST)' test 2>&1 \
		| grep -E "error:|failed|XCTAssert|Test skipped|Executed .* tests?, with" | grep -v "^Test Suite" \
		| awk '/Executed/ { last = $$0; next } !seen[$$0]++ { print } END { print last }'

phone-run: phone-build
	@APP=$$($(PHONE_XCB) -destination '$(PHONE_DEST)' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/OriPass.app; \
	xcrun simctl boot "$(PHONE_SIM)" 2>/dev/null || true; \
	xcrun simctl install "$(PHONE_SIM)" "$$APP" && \
	xcrun simctl launch "$(PHONE_SIM)" com.meric.oripass.ios $(PHONE_ARGS)

# The app, Safari and the AutoFill sheet driven on the simulator, against the
# stand-in on localhost:8099, which is started for the run and stopped after.
phone-ui: SHELL := /bin/bash
phone-ui: phone-gen
	rm -rf /tmp/oripass-ui.xcresult /tmp/oripass-ui-shots
	cd Phone && { python3 -I scripts/standin.py --port 8099 > /tmp/oripass-standin.log 2>&1 & echo $$! > /tmp/oripass-standin.pid; }
	set -o pipefail; xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -configuration Debug \
		-destination '$(PHONE_DEST)' -resultBundlePath /tmp/oripass-ui.xcresult test $(PHONE_UI_ONLY) 2>&1 \
		| grep -E "error:|failed|XCTAssert|Test skipped|Executed .* tests?, with|xcresult" | grep -v "^Test Suite" | sort -u; \
		status=$$?; kill $$(cat /tmp/oripass-standin.pid) 2>/dev/null; \
		xcrun xcresulttool export attachments --path /tmp/oripass-ui.xcresult --output-path /tmp/oripass-ui-shots > /dev/null 2>&1; \
		exit $$status

# Face ID on the simulator: a face enrolled, a sign-in, the vault opened again
# by the face, then by the password (Phone/scripts/face-ui.sh).
phone-face: phone-gen
	xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -destination '$(PHONE_DEST)' build-for-testing -quiet
	Phone/scripts/face-ui.sh

# AutoFill on the simulator: a sign-in, AutoFill switched on for OriPass in
# Settings, and each AutoFill test, with Face ID's match sent while they run.
phone-autofill: phone-gen
	xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -destination '$(PHONE_DEST)' build-for-testing -quiet
	Phone/scripts/autofill-ui.sh $(PHONE_AUTOFILL_TESTS)

PHONE_AUTOFILL_TESTS := AutoFillUITests/testTheSuggestionIsThereWhileLocked FillUITests/testOneTapFillsBothFields \
	ListUITests/testOneTapInTheListFillsAnApp ListUITests/testTheSitesLoginsComeFirstInSafari \
	ListUITests/testThePasswordOpensTheList ListUITests/testANewLoginFromTheListFillsThePage AutoFillUITests/testTheAppTurnsItOn \
	AutoFillUITests/testSettingsTurnsItOnAndTheStoreIsFilled CodeUITests/testTheCodeIsOfferedAndFilled \
	SaveUITests/testASignUpIsSavedToTheVault GraceUITests/testChooseAMinute GraceUITests/testFillsWithoutAFace \
	PasskeyUITests/testAPasskeyIsMadeAndSignsIn

# The app's writes and a passkey made in Safari, to a stand-in that keeps
# them, read back by Bitwarden's own CLI (Phone/scripts/edits-ui.sh).
phone-edits: phone-gen
	xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPassUI -destination '$(PHONE_DEST)' build-for-testing -quiet
	Phone/scripts/edits-ui.sh

# A Release build to TestFlight for internal testing, signed by the team in
# Phone/Team.xcconfig (Phone/scripts/testflight.sh). The app's record on App
# Store Connect has to be there first.
phone-testflight: phone-gen
	Phone/scripts/testflight.sh

# Bitwarden's own CLI reads the stand-in's invented account and every item
# it decrypts is what Phone/scripts/make-vault.py put in.
phone-bw-check:
	cd Phone && scripts/bw-reads-standin.sh

# On the iPhone plugged in, a Release build signed by the team in
# Phone/Team.xcconfig. Xcode registers the phone, the app ids, the App Group
# and the AutoFill entitlement with that team the first time. Release, so
# that nothing a Debug build keeps for the simulator's tests is on the phone.
PHONE_RELEASE := xcodebuild -project Phone/OriPassPhone.xcodeproj -scheme OriPass -configuration Release

phone-device: phone-gen
	@test -f Phone/Team.xcconfig || { echo "Phone/Team.xcconfig is missing: see Phone/README.md."; exit 1; }
	$(PHONE_RELEASE) -destination 'generic/platform=iOS' -allowProvisioningUpdates build -quiet
	@APP=$$($(PHONE_RELEASE) -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/OriPass.app; \
	DEVICE=$$(xcrun devicectl list devices --hide-headers 2>/dev/null | awk '/available/ {print $$3; exit}'); \
	test -n "$$DEVICE" || { echo "No iPhone is plugged in and unlocked."; exit 1; }; \
	xcrun devicectl device install app --device "$$DEVICE" "$$APP"

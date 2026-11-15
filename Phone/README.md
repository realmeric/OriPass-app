# OriPass for iPhone

The iPhone app for the same Bitwarden account as the Mac app. It signs in, syncs and decrypts on the phone itself, keeps the vault's key behind Face ID, and fills logins, one-time codes and passkeys through iOS's AutoFill. `docs/notes-ios.md` has the facts it is built on.

Everything up to the phone is built and tested on the simulator against a stand-in server and an invented account (`make phone-test`, `make phone-autofill`). These are the steps to a phone of your own, in the order they are taken.

1. An Apple Developer Program team. `Phone/Team.xcconfig`, which git ignores, names it in one line: `DEVELOPMENT_TEAM = <your team id>`.
2. Once, in App Store Connect, Apps, the plus, New App: iOS, any name the App Store does not already have, the bundle id `com.meric.oripass.ios` (or your own, changed in `Phone/project.yml`), any SKU. App Store Connect's API cannot make this record.
3. From the repository's folder:

       make phone-testflight

   A Release archive in `$TMPDIR`, numbered by the clock, uploaded for internal testing only. `Phone/scripts/testflight.sh --upload-only` sends the last archive again. In App Store Connect's TestFlight tab, add yourself to an internal group once; each build after reaches the TestFlight app on the phone with no review. `make phone-device` is the other way, by cable, with no App Store Connect at all.
4. Install it from TestFlight.
5. Open OriPass on the phone and sign in: bitwarden.com (or .eu), the email, the master password. Bitwarden emails a code the first time a device signs in to an account with no two-step login; it goes in the field that appears.
6. Tap "Turn On AutoFill", then "Turn On" in iOS's question.
7. Try a login in Safari from the offer, a login in one app, a site that asks for a one-time code, a site with a passkey saved in Bitwarden, and a new passkey made on webauthn.io.
8. "About This Vault" shows the vault in counts and the key derivation, never a value, and whether the account has any string of type 7, the newer format this app does not read yet.

A TestFlight build lasts ninety days; `make phone-testflight` again sends the next.

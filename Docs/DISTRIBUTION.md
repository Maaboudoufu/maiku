# Signed and Notarized Distribution

Plan §16 Milestone 6: "Signed/notarized development distribution documentation if credentials
are available." They are not, on any machine this project has been built on — there is no Apple
Developer Program membership or Developer ID certificate available here. `scripts/build.sh`
ad-hoc signs `Maiku.app` (`codesign --sign -`), which is enough to run locally and for TCC
(microphone permission) to track a stable app identity, but an ad-hoc signature is not
recognized by Gatekeeper on another Mac and cannot be notarized.

This document is the runbook for whoever has those credentials, so distributing a real build
does not require re-deriving this process.

## What's required first

- An active Apple Developer Program membership.
- A **Developer ID Application** certificate for that team, installed in the signing machine's
  keychain (from Xcode's Signing & Capabilities, or `security` + a CSR against
  developer.apple.com directly — a full Xcode install is the path of least resistance here even
  though building maiku itself does not need one).
- An app-specific password or API key for `notarytool` (`xcrun notarytool store-credentials`).

## Signing

Replace the ad-hoc step in `scripts/build.sh` with a Developer ID signature and the hardened
runtime, which notarization requires:

```bash
codesign --force --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --options runtime \
  --entitlements Maiku.entitlements \
  --timestamp \
  dist/Maiku.app
```

Two differences from the current ad-hoc call matter: `--options runtime` (hardened runtime,
mandatory for notarization) and a real `--timestamp` (ad-hoc builds pass `--timestamp=none`
since an ad-hoc signature can't carry one meaningfully).

`Maiku.entitlements` already declares exactly the App Sandbox entitlements plan §12 asks for
(`app-sandbox`, `device.audio-input`, `network.client`, `files.user-selected.read-write`) — the
hardened runtime does not require anything beyond what's already there for a sandboxed app.

## Notarization

```bash
ditto -c -k --keepParent dist/Maiku.app dist/Maiku.zip
xcrun notarytool submit dist/Maiku.zip --keychain-profile "maiku-notary" --wait
xcrun stapler staple dist/Maiku.app
```

`--wait` blocks until Apple's automated check finishes (usually a few minutes). If it rejects
the build, `xcrun notarytool log <submission-id> --keychain-profile "maiku-notary"` gives the
specific reason — most commonly a missing entitlement, an unsigned nested binary, or a
non-hardened-runtime signature.

## Verifying before shipping

```bash
codesign --verify --deep --strict --verbose=2 dist/Maiku.app
spctl --assess --type execute --verbose dist/Maiku.app
```

The second command is the actual Gatekeeper check a user's Mac performs — it should report
`accepted`, `source=Notarized Developer ID`.

## What does not change

The dependency-pinning, the Swift package structure, and every entitlement already reflect what
a notarized build needs — none of that is gated on credentials. The only gap is the signing
identity and the notarization step above; nothing else about this project's structure or build
process changes once those are available.

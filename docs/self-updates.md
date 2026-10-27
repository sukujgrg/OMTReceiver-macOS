# Sparkle self-updates

OMTReceiver uses **Sparkle 2.9.6**, pinned in its Xcode project and package resolution. Its feed is:

`https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest/download/appcast.xml`

The application requires Ed25519-signed feeds and update archives, and verifies updates before extraction. The updater belongs to the application, independent of the number of receiver windows. Manual checks use Sparkle's native download, installation and error UI. Automatic checks use gentle reminders; automatic installation is disabled. A user-initiated update restart passes through the normal application termination path, which retires receiver sessions and discovery before exit.

The app is unsandboxed. Sparkle's sandbox installer/downloader flags and Mach exceptions are unnecessary and are deliberately absent. App and embedded OMT code retain library validation; all shipped libraries are signed with the same team.

## Signing identity

Use a separate persistent Keychain key under **com.suku.OMTReceiver-macOS**. Do not reuse or alter eucaly's key. Only the public key belongs in `OMTReceiver/Resources/Info.plist` as `SUPublicEDKey`. Preserve the private key across releases and transfer it securely when replacing the release Mac. Never generate a fresh key for each release.

Resolve the pinned tools and inspect the app's existing public key with:

```sh
xcodebuild -resolvePackageDependencies -project OMTReceiver.xcodeproj \
  -scheme OMTReceiver -derivedDataPath build/DerivedData
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.suku.OMTReceiver-macOS -p
```

For initial setup, use `scripts/setup-update-signing.sh`. The script must be run only for this app's initial identity or to read its existing public key; it does not belong in an ordinary build/release step. Keychain access may require the maintainer's approval. The release engine checks the public key against the source template before archiving and refuses a mismatch. Neither release script exports the private key.

## Feed history and the first release

`make release` signs both archive and appcast using the pinned Sparkle tools. Only an empty release repository may start a feed without previous signed history. After that, the previous appcast must be available and its signature must verify. Build numbers advance past all prior entries; retained archive/signature/size and minimum-OS/hardware eligibility cannot be changed.

Until the first release publishes `appcast.xml`, manual checks may report an update-information retrieval error. This is a missing published feed, not an installer fallback. See [releasing.md](releasing.md) for the first-release prerequisites and resumable workflow.

## Checks

`make test` includes injected updater tests and offline version/feed/release regressions. These should not contact the production feed or install an update. Before distribution, verify a signed/notarized pair in a disposable installation: download, installation, relaunch, a canceled/interrupted update, corrupt archive, unavailable network, and update while receivers are active. Confirm per-view mute, display preference and normal receiver cleanup survive the restart.

Sparkle references: [gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/), [publishing signed updates](https://sparkle-project.org/documentation/publishing/), [sandbox guidance](https://sparkle-project.org/documentation/sandboxing/).

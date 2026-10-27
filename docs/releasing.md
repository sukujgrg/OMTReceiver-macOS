# Releasing OMTReceiver

OMTReceiver uses the same local build and release entry points as eucaly. The application and Sparkle feed belong to **sukujgrg/OMTReceiver-macOS**, separate from the tvOS receiver. Credentials remain in the release Mac's Keychain; GitHub Actions validates source without signing or publishing.

## Everyday build

```sh
make build
```

This runs `scripts/build.sh`: archive the arm64 application, export with Xcode's `mac-application` method, and install `OMTReceiver.app` in `~/Applications`. The app retains hardened runtime and library validation, and the embedded OMT libraries are signed with its team. `make run` opens that installed application. This replaces the earlier ad hoc `build/OMTReceiver.app` workflow.

`VERSION` is the sole marketing-version source for both Xcode and Make builds. The build phase generates an Info.plist in DerivedData before signing. Source commit and build-number overrides used by release preparation are written during this generation, never into a signed app. Keep `SKIP_INSTALL=NO` on the application target only; an archive-command override can accidentally install package objects and produce a generic archive.

## First-time setup

1. Use a Git checkout whose single HTTPS `origin` push URL is `https://github.com/sukujgrg/OMTReceiver-macOS.git`.
2. Select the configured development team in Xcode. Distribution requires a valid **Developer ID Application** certificate in the local Keychain.
3. Create a **new Apple app-specific password** labeled `OMTReceiver macOS notarization` in [Apple Account → Sign-In and Security → App-Specific Passwords](https://support.apple.com/en-us/102654). Run `make setup-notarization` in your local Terminal to store it under the dedicated **OMTReceiverNotary** profile. Apple's tool prompts for your Developer Apple ID, password and team (this checkout's configured team is `E5N29VFW8T`), validates the credentials, and stores them in Keychain. Do not paste the password into chat, Make arguments, environment variables or source files. The project does not copy or reuse eucaly's password; renaming a profile alone would not create a separate credential. An explicitly selected alternative profile is supported with `NOTARY_PROFILE=Name`; there is no fallback to another app's profile.
4. Initialize the separate OMTReceiver Sparkle key as described in [self-updates.md](self-updates.md). Its account is **com.suku.OMTReceiver-macOS**; the eucaly signing key is not reused.
5. Push or merge the source to `main` and enable the checked-in **Validate** workflow on the same runner configuration as eucaly (`xcode-27`, Xcode 27.1).

The release commands fail clearly when these prerequisites are missing. They do not create a repository, upload credentials or silently bypass validation.

## Normal release

Finish and commit the application changes first. Run one build or test at a time in a checkout: concurrent `make build`, `make test`, Xcode archives, or `make clean` can collide in DerivedData. Finish those commands before preparing a release.

From a clean checkout, use the next unpublished version. This example shows `1.2.3`; replace it with the version you intend to publish:

```sh
git switch main
git pull --ff-only
git status --short                 # must be empty before changing VERSION
scripts/set-version.sh 1.2.3
git add VERSION
git commit -m "Release 1.2.3"
git push origin main
make release
```

The version bump must be committed and pushed too, even if the application changes were already pushed. Existing Keychain credentials are reused: the dedicated `OMTReceiverNotary` profile and Sparkle account `com.suku.OMTReceiver-macOS` need no new password or key for each release. `make release-check` is an optional preflight; `make release` performs the same checks automatically.

The command requires a clean checkout, derives the repository from the exact HTTPS push URL, checks it against the embedded feed URL, and waits for the latest successful **Validate** push run on `main` for the same source commit. It then:

- Archives arm64 and exports using Developer ID.
- Verifies the app, Sparkle framework/helpers and OMT runtime signatures, architectures, hardened runtime and absence of debugging/library-validation exceptions.
- Notarizes, staples and validates the app.
- Signs the update archive and appcast with the app-specific Sparkle key.
- Creates and pushes `v<VERSION>`, uploads assets to an owned draft, verifies the remote bytes, and publishes that draft as latest.

No separate manual tag is needed. Release version, tag, build number, repository and team are derived; Make rejects overrides for these values. Build numbers are UTC timestamps raised above every previous signed feed entry when necessary.

A genuinely empty release repository can create its first signed appcast. Once any release exists, a missing stable feed is an error. There is no legacy eucaly migration exception. Previously published archive URLs, signatures, lengths and compatibility metadata must remain intact, and the previous appcast must verify before it is reused.

## Public commands

| Command | Result |
| --- | --- |
| `make build` | Archive/export the local app into `~/Applications`. |
| `make setup-notarization` | Secure interactive setup of the dedicated notarization Keychain profile. |
| `make test` | Run native app tests plus offline release/feed regressions. |
| `make test-release` | Run only offline release/feed regressions. |
| `make release` | Prepare and publish the signed, notarized release. |
| `make release-check` | Check source, destination and exact-commit CI only. |
| `make release-notarize` | Prepare signed, notarized artifacts without tagging or publishing. |
| `make release-publish` | Publish verified saved artifacts without rebuilding/notarizing. |
| `make clean` | Remove caches while preserving `build/release/`. |

For custom release notes, write a file outside the checkout, then use it instead of the plain `make release` command:

```sh
cat > /tmp/omt-notes.md <<'EOF'
Describe the changes users will receive.
EOF
make release NOTES_FILE=/tmp/omt-notes.md
```

Notes are saved before publication so retries retain the same text. The release engine never force-pushes tags or replaces uploaded release assets.

## Saved work and retries

Preparation is retained under `build/release/v<VERSION>/`: `state.json`, `work/`, exported application, notarization records, zip, checksum, source metadata and signed appcast. The state binds source commit, repository, archive and file hashes to that version. Keep this directory intact. Rerunning the same command resumes verified work instead of rebuilding or resubmitting blindly.

`make clean` and release preparation share a lock in Git's common directory, including linked worktrees, so cleanup cannot remove active preparation. Separate clones or machines still require one publisher at a time. A changed latest stable release stops publication; prepare against the new signed history rather than overwriting it.

If Apple's submission succeeded but the response was lost, use:

```sh
xcrun notarytool history --keychain-profile OMTReceiverNotary
python3 scripts/release.py --no-publish --resume-notarization SUBMISSION_ID
make release-publish
```

The recovered Apple job must match the saved zip hash. Never edit recovery state to skip verification. If the source has changed, return to the recorded commit to finish, or preserve the incomplete directory under another name and prepare the intended source. Published tags require a new version.

## Scope

Offline regression tests use temporary repositories and tool doubles; they do not publish anything or access signing keys. A passing local build is not a notarization result. Test an actual signed/notarized update pair in a disposable installation before distributing the first update, including interrupted download, corrupt archive, unwritable destination, relaunch and active receivers. Fullscreen and media hardware qualification remain independent of release tooling.

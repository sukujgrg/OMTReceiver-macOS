# Version 1.2 validation — 28 October 2026

Version 1.2 replaces the sidebar/player workflow with a native live source grid. Single-click starts a separate full-quality fullscreen receiver; the browser remains available on another display. Clicking the same source keeps output running, clicking a different source switches it, and Escape stops output and restores grid focus.

## Delivered build and native observation

`make build` completed its signed arm64 Release archive/export into `~/Applications/OMTReceiver.app`, version **1.2**, build **261027.132634**. `codesign --verify --deep --strict` passed. The only archive warning was the informational App Intents extraction warning; no new compiler warnings were reported.

The installed final app was opened through native UI automation. Raising the browser started its moving 320×180p15 alpha test-pattern thumbnail. Settings retained DELL P2721Q as the fullscreen target. A single thumbnail click changed its badge to Playing and started the independent 1280×720p60 receiver while the browser remained visible and focused; repeat activation kept output running. Escape cleared Playing, stopped the output and restored collection focus. Native Settings opened while the external output remained active. The external monitor's final 1.2 pixels were not independently captured in this follow-up; the physical external-picture evidence from 1.1 remains below, alongside the current native display/retarget tests.

The final app was left open at the source browser, with the saved external target unchanged and fullscreen output stopped. No live eucaly sender was advertising during this final launch; the previous live eucaly interoperability evidence is preserved below. No release was published.

## Automated results

- **48 native tests, zero failures, one expected optional eucaly integration skip**, in two consecutive complete runs after the final toolbar repair. The **111 offline release/feed checks** also passed during this change.
- Six source-browser regressions cover actual collection layout/card hit testing, single-click versus double-click delivery, keyboard/accessibility activation, independent browse and Playing selection, retained preview identity, address replacement, hidden windows and the 12-worker admission/retirement limit.
- Three preview-transport regressions use the official SDK: reduced video with alpha alongside original-format playback, exactly three media TCP connections (preview video plus playback video/audio), no preview audio, rate admission, tiny frames, color-space defaults and rapid retirement. The sender fixture and receivers retire after each run.
- Native fullscreen regressions cover source switching without a second output window, idempotent repeat activation, display preference retargeting without disconnecting playback, Escape and shutdown joins. Existing format, GPU color/alpha/interlace, audio, reconnection, updater and multi-display tests remain enabled.
- A complete run exposed an AppKit toolbar-family assertion that an isolated test missed. Independent receiver windows had shared a toolbar identifier; native item removal propagated into a sibling with a different lifetime. Each non-customizable toolbar now has its own identifier, with a regression assertion. Temporary exception tracing was removed before the two successful complete runs.

The 12-preview limit is per browser, includes retiring SDK workers, and is not a sustained-throughput or total-memory guarantee. Preview video requests the official reduced-resolution stream, is admitted/rendered at up to 15 fps and opens no audio connection. Fullscreen preserves the original stream format through its separate receiver. No new latency, audible-quality, physical hot-unplug or broadcast-scanout qualification is claimed.

Logs: `build/Logs/toolbar-family-fix-full-{1,2}.log` and `build/Logs/make-test-1.2-final.log` (the earlier failing complete run, including passing offline checks). The final native results are under `build/DerivedData/Logs/Test/`; the signed build log is `build/Logs/make-build-1.2-final.log`.

---

# Version 1.1 validation — 27 October 2026

The original 1.0 evidence is preserved below. Version 1.1 repairs external-display fullscreen and adds eucaly-style signed builds, release tooling and Sparkle 2.9.6.

## Current automated results

- `make build`: signed arm64 Release archive and `mac-application` export succeeded into `~/Applications/OMTReceiver.app`. Hardened runtime and library validation remain enabled. Version/build are generated from `VERSION` before signing.
- `make test`: **111 offline release/feed checks passed**, plus **38 native tests with zero failures and one expected optional eucaly integration skip**. A live eucaly sender was not launched for this follow-up; its earlier reception evidence is recorded below.
- Native regressions exercise initial window placement on both connected DELL displays, external-target changes retaining the same video surface, negative/vertical coordinate arrangements, injected target removal, shared updater state, native Settings construction and light/dark bounds, same-display stacked fullscreen dialog handling and preserving fullscreen on another display.
- Updater component checks inject the resolver's key-window dependency and verify window visibility, retained video ownership and local first-responder restoration. They do not claim WindowServer foreground focus while the Mac is locked.
- A local **Developer ID archive/export** passed the strict distribution validator: matching team, hardened runtime, arm64 and no debugging or library-validation exceptions across the app, Sparkle helpers and OMT libraries. No notarization or publication was performed. Local `mac-application` exports retain some Sparkle vendor helper signatures, matching eucaly; Developer ID export re-signs them as required.
- `make release-check` correctly refuses the current uncommitted source. The local `main` repository is initialized with `origin` set to `https://github.com/sukujgrg/OMTReceiver-macOS.git`. The remote still requires initial creation/push and a successful Validate run before release.
- The OMTReceiver-specific Sparkle key was created in Keychain under `com.suku.OMTReceiver-macOS`; only its public key is in the source template. The eucaly key was not changed or exported.

The first native test run exposed a common-ancestor constraint exception in the new Updates status label; the label is now inserted before its constraint is activated, and the final suite passes. A subsequent global focus assertion could not activate the XCTest host while the Mac was locked; the test now checks its component's window/responder ownership without claiming OS foreground activation. Earlier failures remain in their logs.

## Fullscreen cause and repair

The old application was observed to show black fullscreen output on the selected DELL P2721Q, while Escape returned its moving test pattern. The external screen begins at `(2560, 0)`. The original explicit-screen NSWindow initializer received the global screen frame, adding the screen origin twice before MetalKit attached. Correcting the frame afterward did not establish the proper initial display association.

The new presentation window starts with a screen-local content rect, belongs to the target screen before the video view attaches, and uses the same native projection level/Space behavior as eucaly. The same receiver/video surface survives entry, target change and Escape. Explicit Settings/update dialogs reveal receivers covering the invoking display; scheduled reminders do not change fullscreen state or focus.

Final physical picture verification was initially blocked because the native UI tool reported the Mac locked. After it became available, the **installed final 1.1 build** was inspected through native accessibility and screenshots: Settings selected DELL P2721Q (1920×1080 logical points), fullscreen showed the complete color bars/alpha ramp on its 3840×2160 backing surface, and consecutive captures showed the white motion marker at different positions. Repeated entry and Escape returned the same normal receiver window. Opening Settings from external fullscreen revealed the native Settings window and update controls correctly. The old black-output reproduction and the repaired non-black moving picture are distinct observations; no physical hot-unplug, interlaced scanout, or audible-quality qualification was added.

Logs: `build/Logs/make-test-1.1-final.log`, `build/Logs/make-build-1.1-final.log`, `build/Logs/distribution-{archive,export}-1.1-final.log`. The final native result is under `build/DerivedData/Logs/Test/`.

---

# Validation — 27 October 2026 (Australia/Sydney)

## Delivered build

- Final optimized arm64 macOS application: `build/OMTReceiver.app`.
- Conventional Xcode project: `OMTReceiver.xcodeproj`, shared OMTReceiver scheme.
- Xcode 27.1, macOS SDK 27.0; deployment target macOS 14.0.
- Final Release build succeeded. No Swift/C compiler warnings. Xcode emits its informational warning that App Intents extraction is skipped because the app has no AppIntents dependency.
- `codesign --verify --deep --strict` passed for the app and both embedded SDK libraries (local ad hoc signing). The final local Release invocation disables hardened runtime because ad hoc libraries have no Team ID; Developer ID builds retain the project’s hardened runtime setting. A standalone-launch check caught this distinction after the hosted tests; the corrected packaged app was checked separately.
- All vendored SDK files match the hashes in `Vendor/OMT/provenance.json`.

## Automated evidence

Final `build/Tests-final.xcresult`: **25 tests, zero failures, zero skips**. The eucaly integration was explicitly enabled against the exact test-owned helper's loopback TCP listener.

- 4 model/clock/preferences checks: IPv4/IPv6/address rejection, rational NTSC clock/A/V offsets, restart mapping and preference persistence.
- 6 malformed/native-frame checks: buffer ownership, stride/plane truncation, bounds, interlace metadata, UHD dimensions, 16-bit planes and 44.1/96 kHz planar PCM.
- 3 official-SDK loopback/lifetime checks: two simultaneous receivers, 480i59.94 fields/s, alpha 720p59.94, PA16, stereo 44.1/48 kHz, repeated source retirement, and automatic recovery using the same receiver after its sender is destroyed/recreated.
- 8 actual Metal GPU readback checks: Rec.709 limited-range endpoints/chroma, straight/premultiplied alpha, checkerboard, UYVA, PA16, independent bob fields versus weave, and floating-point drawable precision finer than 8-bit.
- 3 native AppKit checks: independent window/source/mute ownership, same-surface fullscreen/Escape/geometry restoration, minimum-size source browser and Settings controls.
- 1 genuine eucaly integration: accepted Current generated video → eucaly compositor/helper → official OMT → receiver → actual VideoView presentation, 1920×1080p30 Rec.709 and stereo 48 kHz PCM, plus Bonjour discovery of the real source.

The isolated eucaly test fixture used existing prebuilt application/test products from the eucaly project and its production-source XCTest. Its own final run passed and acknowledged Finish; the sender and helper retired. It did not open an operator library or native projection output. Evidence is under `build/eucaly-source-3/`, including its result bundle and control acknowledgements. Earlier bounded source runs and failed test attempts are retained separately.

## Native observation

The normal application was opened and inspected using its native accessibility tree and screenshots. Observed the animated alpha test pattern, real eucaly source appearing in the sidebar, source selection reaching Live at 1920×1080p30 Rec.709, the real generated eucaly picture in fullscreen, Escape returning to the normal window, mute, and native Settings controls. The SDK discovery poll now updates the source list only on changes, preserving native row identity and keyboard focus.

Early Xcode-hosted eucaly attempts received video/audio successfully but did not receive Bonjour replies. The unchanged discovery class worked in standalone native probes. After a normal app launch established local-network permission (System Settings showed OMTReceiver enabled), both native source selection and the final unchanged discovery assertion passed. No permission bypass or silent test relaxation was added. The earlier failures remain in the retained logs/result bundles.

## Scope limits

This establishes buildability, bounded ownership, native lifecycle, actual SDK interoperability and GPU pixel mathematics. It does **not** establish audible quality, measured end-to-end latency or lip sync, sustained high-load multiview throughput, physical hot-unplug across multiple monitors, field-synchronized broadcast scanout, or Developer ID notarization. The discovery-server configuration uses the real SDK API but no external discovery server was available for a live server run.

Automatic interlaced-mode selection is implemented through the active Core Graphics display-mode flag; AppKit does not guarantee field-synchronized scanout. The low-latency spatial deinterlacer can soften fine vertical detail. HDR/Rec.2020 metadata is outside the pinned SDK interface. These limits are also stated in the README and application Help.

Logs: `build/Logs/build-tests-final.log`, `build/Logs/build-release-local.log`. Result bundles and build output are intentionally ignored by Git.

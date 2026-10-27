# Dedicated notarization integration — 28 October 2026

The dedicated-notary worktree integrates all completed follow-up receiver changes and the owner's `OMTSender/` ignore rule. No sender-project files are part of this repository. The completed audio QoS/teardown, playback activity, visibility, accessibility and controls-routing evidence below is retained.

The release Make targets and direct CLI now default to **OMTReceiverNotary**, with no automatic fallback to eucaly's profile. `make setup-notarization` requires an interactive local Terminal and lets Apple's tool prompt directly; the password is not accepted in Make/CLI arguments, exported through an environment variable or saved in project files. A genuinely new Apple app-specific password still needs to be generated and entered by the owner. No existing Keychain credential was inspected, copied, changed or revoked during this integration.

The combined `make test` passed **88 native tests, zero failures, one optional eucaly skip**, plus **114 offline checks** (9 signed-feed and 105 release-workflow tests). Added regressions verify the dedicated CLI/Make defaults, explicit custom-profile propagation across every notary operation, and refusal to access credentials from a noninteractive setup command. Integration log: `build/Logs/combined-notary-review-test.log` in the dedicated-notary worktree.

---

# Core Audio teardown QoS repair — 28 October 2026

The earlier native trace correctly located a synchronous wait inside `AVAudioPlayerNode.stop()`, but stopping at the framework stack missed two app-side causes: `AudioPlayer` classified its non-real-time graph-control queue as `.userInteractive`, and its finalizer could call native stop directly on the main/UI thread.

The same private serial queue now explicitly uses `.default` QoS for graph construction, PCM submission, volume, reset and retirement. `AVAudioEngine` still owns the real-time render thread; that thread's scheduling is unchanged. At final `AudioPlayer` release, graph ownership transfers to the original control queue, which performs native stop and the graph's final ARC release. No separate overlapping teardown queue was added. Both source/render generation fences, the admission lock, scheduled-duration bounds, native player/engine stop calls and old-stop-before-replacement order remain intact. No diagnostic, checker setting or warning was suppressed. This classification follows [Apple's guidance for APIs with internal synchronization](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early).

Two new regressions verify actual execution and ownership rather than a queue property's declared value:

- UI-originated graph operations, explicit stop, last-owner release and renderer destruction execute off the main thread at effective default QoS. The test waits for temporary control-operation retains to finish before dropping the sole player reference on MainActor. The initial run against the old implementation failed, observing UI QoS and final native stop on the main thread.
- A deliberately blocked old renderer stop keeps UI cancellation/admission responsive, prevents replacement graph creation from overtaking retirement, rejects a canceled intermediate source and preserves the admitted replacement's mute state.

All **12 focused audio tests** passed, including real output-mixer signal, mute/silence, unmute and `.dataPlayedBack` completion. `make test` passed **88 native tests, zero failures, one expected optional eucaly skip**, plus **111 offline release/feed checks**. After strengthening the sole-reference regression, the complete native suite passed again with the same counts. Xcode's structured final result reports `runtimeWarnings: []`; the logs contain no teardown priority-inversion diagnostic. The Thread Performance Checker settings are unchanged.

Final native result: `build/DerivedData/Logs/Test/Test-OMTReceiver-2026.10.28_04-47-09-+1100.xcresult`. Evidence: `build/Logs/audio-qos-regression-before-fix.log`, `audio-qos-focused-after-fix.log`, `audio-qos-full-suite-final.log`, `audio-qos-native-suite-final.log` and `audio-qos-final-result-summary.json`. The original symbolication evidence remains in `build/Logs/audio-stop-priority-investigation.txt`; its recommendation to leave the warning unresolved is superseded by this repair.

`make build` archived/exported signed **1.2.1 / 261027.174803** into `~/Applications/OMTReceiver.app`; strict deep signature verification passed. Build log: `build/Logs/audio-qos-signed-build.log`. The installed bundle is updated; an already-running receiver needs relaunching to load the new code. No active operator playback was interrupted for this follow-up.

No new physical speaker, device-route-removal, sustained-load or A/V timing qualification is claimed. The real Core Audio graph regression verifies rendered samples and playback completion through the current output route.

---

# Version 1.2.1 verification follow-up — 28 October 2026

The earlier repair commit `19fb860` already addresses the nine review findings through display ownership, per-track media health, native control presentation, PCM admission, recovered renderer state, accessible Settings, native button tracking, deliberate preview retry and safe-area geometry. This follow-up independently checked those changes and repaired the remaining lifecycle gaps.

## Additional root repairs

- Full-quality fullscreen output now owns a scoped Foundation `ProcessInfo.beginActivity(options:reason:)` activity using `[.userInitiated, .idleDisplaySleepDisabled]`, paired with `endActivity(_:)`. No synthetic input, repeated timer, power-setting change or helper process is used to keep the Mac awake. Controls and repeat activation retain one scope; retargeting preserves it; replacement acquires its scope before the displaced receiver releases its scope; exit, missing-target failure and controller retirement release it. This follows Apple's presentation example in `NSProcessInfo.h` and [Foundation activity documentation](https://developer.apple.com/documentation/foundation/processinfo/activityoptions).
- The source browser explicitly observes minimize/restore and view hide/unhide, alongside window occlusion, so preview retirement does not depend on a coincident WindowServer notification.
- Source buttons expose accessible browse selection independently from their Playing value.
- Show Sources uses the same application-level controls resolver as Settings and connection dialogs. It can reveal a browser covered by another receiver's projection without stopping that receiver. The regression checks source/surface preservation, focus and window ordering on the two connected displays.

## Automated evidence

The final serial run executed **86 native tests, zero failures, one expected optional eucaly skip**. The optional isolated eucaly sender was not started again for this follow-up; its previous successful run is preserved below. The **111 offline release/feed checks** passed. No build overlapped the implementation chat's validation.

New regressions cover activity lifetime and handoff ordering, presentation-option restoration in both display exit orders, cross-window Show Sources, visible/occluded/minimized/hidden preview transitions with pending-worker retirement, source identity through Playing changes and discovery reorder, responder-chain arrow/Return routing, accessible selection, native popup-cell values, mute without fresh input, matching versus unrelated audio configuration changes, and real Core Audio rendering.

The real audio test sends generated 48 kHz stereo PCM through the shipped `CoreAudioRenderer` and `AudioPlayer`. A tap on the app's own output mixer observes nonzero signal, muted silence and restored signal after unmute; actual `.dataPlayedBack` callbacks must complete, and mute must retain the same running graph. It requires an output route and uses no microphone. This establishes digital graph output, not audible speaker quality.

The first follow-up run exposed an incorrect test assumption: the outer `NSPopUpButton` is ignored in AppKit's accessibility hierarchy; its native cell exposes the selection value. The corrected regression uses `NSAccessibility.unignoredDescendant(of:)`, verifies the popup role/value and confirms AppKit updates the value after selection changes. No application AX-value workaround was introduced.

This run reported a Thread Performance Checker priority-inversion diagnostic during `AVAudioPlayerNode.stop()`. Symbolication identified Apple's internal timer cancellation (`AVAEDispatchQueueTimer::CancelTimer` through `AVAudioPlayerNodeImpl::StopImpl`) synchronizing with its default-QoS timer queue. Test tap removal completed beforehand. The subsequent Core Audio QoS repair above corrects the app-side queue classification and final-release path; the warning is no longer present. Historical investigation: `build/Logs/audio-stop-priority-investigation.txt`.

Final test result: `build/DerivedData/Logs/Test/Test-OMTReceiver-2026.10.28_04-29-37-+1100.xcresult`. Logs: `build/Logs/review-followup-native-tests-routing-final.log` and `build/Logs/review-followup-offline.log`. Earlier diagnostic runs are retained.

## Signed build and native observation

`make build` archived/exported the signed **1.2.1 / 261027.173021** app into `~/Applications/OMTReceiver.app`. `codesign --verify --deep --strict` passed using normal macOS trust services. Build log: `build/Logs/review-followup-signed-build-final.log`. No commit, push or release was performed by this follow-up.

Two bounded, isolated official-SDK fixtures supplied distinct moving 1280×720p60 sources with stereo 48 kHz PCM. No operator sender app or library was modified. Native UI verification on the preceding signed build `261027.172339` observed:

- Moving full-quality pixels on the connected DELL P2721Q's 3840×2160 backing surface, with the marker in different positions in consecutive captures. The browser was moved onto that display to bring the existing output key for direct capture, then returned to DELL U3223QE.
- Arrow browsing without starting output, Return and Space activation, Escape and Command-W stopping output and restoring collection focus, and repeated activation retaining output.
- Two receiver windows exchanging ownership of the configured display, with the displaced browser returning to Sources and each browser retaining its own mute state.
- Show Sources and a canceled Connect to Address sheet retaining Playing. Native Settings exposed the named Playback popup controls.

The final build adds only the cross-window Sources resolver repair to that tested application behavior. Its native minimize/restore check recorded the fixture's actual preview connection count changing **1 → 0 → 1**. The final cross-window Sources case passed its native AppKit regression; further interactive checks were stopped when live operator interaction with the receiver was observed, preserving the current output.

Read-only `pmset -g assertions` confirmed an OMTReceiver-owned **PreventUserIdleDisplaySleep** and **PreventUserIdleSystemSleep** assertion named “Receiving fullscreen OMT video and audio” during output. After Escape, the app's assertions disappeared and the display assertion count was zero. The final installed build's active output also held the same assertions. Evidence is under `build/native-verification/assertions-*.txt`; the fixture's connection ledger is `build/native-verification/fixture-final.log`. Both isolated senders retired cleanly. The app was left running with the operator's current Test Pattern output intact.

Physical cable unplug, actual idle-timeout/screen-saver transitions, explicit sleep/wake, camera-housing hardware, audio device removal/route changes, audible speaker quality, sustained 12-source load and measured end-to-end A/V synchronization remain unqualified. The scoped native activity and its OS assertions were verified; they do not override explicit system sleep. Full VoiceOver navigation was not performed in this follow-up.

---

# Version 1.2.1 independent review — 28 October 2026

A separate fresh chat reviewed the original `ed7c7a0` app independently against current Apple guidance and inspected the installed UI. Separate engineering reviews checked media lifetimes, buffering, discovery and tests. Follow-up review found no remaining blocking issue in the repaired ownership, control presentation, retry, error-health and geometry paths. This is bounded qualification, not a promise that every hardware/network combination is issue-free.

## Root causes repaired

| Area | Repair and evidence |
| --- | --- |
| Hidden/stacked output | A weak, main-actor display registry assigns one fullscreen owner per physical display. Replacement exits the displaced receiver through its normal video/audio teardown. A → B → A activation is covered. |
| Single-display operation | Same-screen viewing uses normal window level/current Space; external projection retains its separate projection policy. Tests inject exactly one screen, exercise a missing saved external UUID, source switching, controls, Escape and Close Window. Browser movement refreshes presentation policy. |
| Native controls during playback | Showing Sources, Settings, updates or a connection sheet changes window order rather than disconnecting the receiver. Retargeting preserves the current controls window and its intent until explicit output activation; native window-order regressions cover this. |
| Wrong keyboard source | Native card action tests exposed additive programmatic collection selection. Activation, focus restoration and snapshot restoration now replace the selection atomically. A second-source click leaves only that source selected. |
| Pointer activation | Cards use native NSButton release-inside tracking. App code has no mouse-down activation or custom tracking loop. Unit tests cover action/selection/hit identity and accessibility; real standalone drag cancellation and double-click behavior were qualified separately. |
| Track freshness | Video and audio have independent health and recovery states. Real SDK regression keeps audio flowing while video stops, asserts partial loss, then recovery. Rejected video cannot become a falsely healthy audio-only source. |
| Oversized PCM | Every admitted chunk fits the 300 ms incoming bound; oversized planar PCM keeps the newest sample-aligned window with adjusted timestamps. The 350 ms scheduled bound and source/renderer epoch fences have hardware-independent regressions across sample rates. |
| Persistent false errors | Audio and video expose current health instead of stale error payloads. Successful scheduling/allocation clears transient errors; old-source errors are fenced. Fatal renderer initialization errors remain visible. |
| Preview recovery | Terminal worker failure is generation-scoped. Control-click → Retry Preview deliberately reconnects only an active failed preview without bypassing retirement or the preview budget. |
| Accessibility and identification | Playback popups have explicit accessible names; changed card values post notifications. Output titles track source changes. Receiver-specific commands do not silently target another window while Settings is key. |
| Interlaced edges and camera housing | GPU field reconstruction clamps before field-parity selection, preventing opposite-field contamination at scaled edges. Fullscreen retains a black full-screen background while fitting video inside NSScreen safe-area insets. |

The native-button choice follows Apple's documented [transparent-button tracking behavior](https://developer.apple.com/documentation/appkit/nsbuttoncell/istransparent). Fullscreen/control and camera-housing decisions were checked against [Apple fullscreen guidance](https://developer.apple.com/design/human-interface-guidelines/going-full-screen) and [NSScreen safe areas](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets); control names follow [Apple's VoiceOver criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria/).

## Automated and interoperability evidence

`make test` with the isolated eucaly endpoint: **78 native tests, zero failures, zero skips**, plus **111 offline release/feed checks**. The final result is `Test-OMTReceiver-2026.10.28_01-26-44-+1100.xcresult`; log: `build/Logs/make-test-1.2.1-review-final.log`.

New coverage includes seven audio scheduling/admission tests, seven actual video-mailbox policy tests, four media-health tests, two preview retry tests, three renderer health/allocation tests, scaled GPU field edges, display ownership, single-screen fallback, safe-area geometry, dialog ordering, receiver command context and atomic source selection. Existing SDK transport, malformed-frame, color/alpha, reconnect and updater tests remain enabled.

The genuine eucaly production compositor/helper fixture was launched using prebuilt test products, a fresh run ID and explicit 180-second bound, with no operator library or native projection. Its verified helper endpoint supplied 1920×1080p30 Rec.709 and stereo 48 kHz PCM to the receiver, actual Metal presentation and Core Audio graph, plus Bonjour discovery. The receiver test passed with no current audio error. Sender run `D02349E1-FE98-4CDE-9011-07402305D368` completed with zero active outputs, all owned helpers/native windows retired and no invariant violations. Evidence: `build/eucaly-review-1.2.1/`.

The initial hosted Validate run also passed: [40513240573](https://github.com/sukujgrg/OMTReceiver-macOS/actions/runs/40513240573). The updated [hosted workflow](https://github.com/sukujgrg/OMTReceiver-macOS/actions/workflows/validate.yml) checks generated-project consistency, pinned SDK hashes, tests, Release archive, arm64 slices and Sparkle metadata, and preserves diagnostics even on failure. Hosted checks skip only environment-dependent cases when no second display or isolated eucaly sender exists; those cases ran locally without skips.

## Native observation and scope

The signed 1.2.1 app was inspected through native UI automation. Actual thumbnail click, drag-out cancellation, subsequent double-click, Return activation, moving full-quality main-display picture, Escape, Close Window, Settings retargeting without focus loss, connection-sheet cancellation preserving Playing, and named Settings controls were observed. The saved DELL P2721Q destination was restored afterward. Native synthetic pointer injection in the inactive XCTest app could not reproduce a real WindowServer event stream; those diagnostic attempts were removed rather than presented as passing physical UI tests. App-owned button action/selection assertions remain automated and caught the real multi-selection defect.

Single-display tests expose exactly one screen even on the local two-display Mac; the hosted runner also has no second display. Native main-display viewing was checked with the external monitor still physically connected. Physical hot-unplug, camera-housing hardware, sleep/wake/screen-saver behavior, sustained 12-source load, audible quality and measured end-to-end A/V synchronization remain separate hardware qualification. No signed distribution release was published during this review.

---

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

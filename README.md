# OMTReceiver for macOS

[![Validate](https://github.com/sukujgrg/OMTReceiver-macOS/actions/workflows/validate.yml/badge.svg)](https://github.com/sukujgrg/OMTReceiver-macOS/actions/workflows/validate.yml)

A standalone **AppKit macOS application** for receiving Open Media Transport video and audio. This is a complete Xcode application project, with independent receiver windows, native source lists, menus, Settings, display-aware fullscreen, Metal video and Core Audio playback. The application UI uses AppKit throughout; eucaly is used only as a testing reference and optional sender.

[Website and download](https://sukujgrg.github.io/OMTReceiver-macOS/) · [Latest signed, notarized release](https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest)

## Build and run

Requires **Apple Silicon, macOS 14 or later, and Xcode 16 or later**. The bundled OMT transport is arm64. The project targets the same signing team as eucaly, and pins **Sparkle 2.9.6** through Xcode Swift Package Manager.

Open `OMTReceiver.xcodeproj`, select the shared **OMTReceiver** scheme and My Mac, then Run. Allow local network access when prompted. The SDK is bundled; no .NET runtime or separate OMT install is required. Xcode resolves the official Sparkle package on the first build.

The Make workflow matches eucaly:

```sh
make build             # signed Release archive/export into ~/Applications/OMTReceiver.app
make run               # build and open that installed app
make setup-notarization # securely store a fresh OMTReceiver-only app-specific password
make test              # native app tests + offline release/feed and website regressions
make release-check     # verify clean source, GitHub destination and exact-commit CI
make release-notarize  # prepare signed/notarized artifacts without publishing
make release-publish   # publish verified saved artifacts
make release           # full validated local release pipeline
make clean             # remove caches while preserving saved releases
```

`VERSION` is the sole marketing-version source. Xcode generates Info.plist in DerivedData before signing; release preparation supplies an advancing build number and verified source commit. Local builds retain hardened runtime and library validation and use your configured Apple Development identity. `make build` is the normal local build command; it no longer produces an ad hoc application under `build/`.

`make test` skips the optional eucaly integration case unless an isolated sender address is supplied. Native tests require a logged-in macOS desktop, Metal and local networking. The test host isolates app preferences and does not start Sparkle or open an operator's eucaly library.

The conventional `.xcodeproj` is checked in and opens directly. `make project` regenerates it using Python 3 when source files are added. No external project generator or optional Metal compiler component is required.

See [release setup and recovery](docs/releasing.md) and [Sparkle self-updates](docs/self-updates.md).

## Live source browser

The normal window shows **live source thumbnails**. Bonjour (`_omt._tcp`) and SDK discovery sources appear automatically, alongside a built-in animated Test Pattern. **Single-click any thumbnail to receive that source at full quality on the configured fullscreen display.** Return or Space opens the keyboard-selected source. Arrow keys browse without switching output; the Playing badge identifies the source currently on the display.

When output is on an external display, the browser stays available on the controls display. Click another thumbnail to switch the existing output. Clicking the same source again keeps it playing. Escape stops that window's fullscreen video/audio and returns focus to the grid. The output picture itself is not a second activation step. Activation uses native release-inside button tracking, so dragging away before release cancels a click.

Each browser has a budget of **12 simultaneous live previews**, including receivers still retiring. The source list can contain more sources; scrolling retires offscreen previews and starts visible ones. Fully hidden/minimized browsers stop preview reception. Cards beyond the active budget clearly show Preview paused. Previews request the SDK's video-only reduced-resolution mode (one eighth of each dimension) and display up to 15 fps, with no audio connection. Fullscreen uses a separate original-format video/audio receiver. If a sender ignores preview mode, its thumbnail reports Preview unavailable rather than continuously decoding a full-resolution fallback.

Stalled previews automatically reopen their own connection, with retry delays increasing from 1 to 30 seconds while the sender remains unavailable. Healthy video resets that delay; slow sources are allowed two frame intervals before being considered stalled, with a three-second minimum. Control-click a stalled or failed thumbnail and choose **Retry Preview** to try immediately. Recovery retains the same preview budget and never restarts fullscreen video or audio. Hidden or closed previews stop retrying; senders reporting Preview unavailable require a deliberate retry.

This is a connection/rendering budget, not a guaranteed throughput or total-memory limit: the pinned SDK still allocates some decoder resources using each source's original dimensions. Capacity depends on the Mac, source formats and network. Multiple browser windows have independent preview budgets and source/mute state. Each physical display has one fullscreen owner: activating output from another browser on that display stops the displaced video and audio.

**File → New Receiver Window** opens another independent source browser/output. Each browser remembers its own output mute state. Browser windows restore their previous size and position across app launches using AppKit frame autosaving. Audio uses the current macOS default output device.

**Connect to Address…** accepts the sender's actual TCP address, for example `omt://192.168.1.20:6400`, `sender.local:6500`, or `omt://[::1]:6400`, and opens it fullscreen. No fixed sender port is assumed. Discovery never selects an output for you, and a playing source remains represented if its advertisement temporarily disappears.

The status strip shows the full-quality output's connection state and format. Source loss retains the last output picture while the official SDK reconnects. If both video and audio remain unavailable, the app automatically reopens that receiver with bounded retry delays, resolving a discovered source's name again. This handles senders such as iPhone cameras that restart on a different TCP port. The fullscreen window and mute setting stay in place; continuing audio-only or video-only reception is preserved. **Playback → Reconnect** tries immediately; **Playback → Stop Output** stops that output and cancels retries. Silent browser previews remain independent. A manually entered address continues to target its specified host and port.

## Fullscreen and displays

Click a live source thumbnail, use the toolbar button, or choose **View → Enter Full Screen**. A full-quality video surface is presented in an AppKit borderless window covering the chosen `NSScreen`, independently of the thumbnail surfaces. Escape closes output and keeps the browser window and geometry intact.

**Settings → Fullscreen display** defaults to the system's main display. A chosen display is saved by its persistent Core Graphics UUID, rather than its transient numeric display ID. The list updates when displays change, and changing the preference moves an active fullscreen view immediately. If the target is absent when entering fullscreen, the main display is used. Unplugging an active target exits fullscreen and returns the normal receiver window. The app never changes a monitor's display mode.

A single-display Mac needs no external monitor. Fullscreen uses its main screen and yields normally when switching apps. **Show Sources**, Settings, updates, and connection dialogs reveal controls without disconnecting playback; click the playing thumbnail to raise the same output again. Escape or Close Window while output is key explicitly stops it. Fullscreen video fits within the screen’s camera-housing safe area, with black around the unobscured picture.

Active full-quality output holds a native Foundation `ProcessInfo` activity with `.userInitiated` and `.idleDisplaySleepDisabled`. This prevents idle system/display sleep and App Nap while receiving, including when controls are visible. The activity survives retargeting, transfers during display ownership replacement, and ends when output stops or its target disappears. Silent thumbnail browsing does not hold an activity. Explicit system sleep remains under the user's control.

| Action | Shortcut |
| --- | --- |
| New receiver window | ⌘N |
| Connect to address | ⌘O |
| Settings | ⌘, |
| Enter / exit fullscreen | ⌃⌘F |
| Exit fullscreen | Escape |
| Mute this receiver | ⇧⌘M |
| Reconnect | ⌘R |
| Stop output | ⇧⌘D |
| Show sources | ⌥⌘S |
| Test pattern | ⌥⌘T |
| Close / quit | ⌘W / ⌘Q |

## Video and audio formats

- SDK-native decoded **UYVY, UYVA, P216, PA16, BGRA and BGRX**. VMX decoding is performed by the official `libomt` / `libvmx` runtime. Opaque YUV is not converted into an intermediate BGRA image.
- SD, 720p, 1080p, 1080i, UHD and other source dimensions/rational rates. Admission bounds are 16–8192 pixels per dimension, up to 240 frames/pairs per second, and 256 MiB per decoded picture. These are resource/safety limits, **not a throughput guarantee**. Actual maximum throughput depends on the Mac, source, network and number of views.
- Source dimensions, display aspect ratio and timestamps remain intact. Pictures fit the view with letterboxing. No forced 1080p conversion or fixed 30 fps timeline. Display refresh limits the number of pictures/fields actually presented.
- Rec.709 and Rec.601 SDR YUV range/matrix handling, with the SDK's SD/HD default for unspecified color space. The shader composites in linear light and presents color-managed sRGB through a 16-bit floating-point drawable, retaining high-depth source precision. Rec.601 uses an SMPTE-C primary assumption. The pinned SDK exposes no Rec.2020, HDR transfer or explicit full-range metadata; unrecognized color-space values are reported as unsupported rather than guessed. HDR tone mapping is not implemented.
- Both **straight and premultiplied alpha**. Choose Black, Checkerboard or White in Settings. The final window itself is opaque; this is source compositing, rather than desktop transparency.
- Interlaced OMT frames retain their two interleaved fields. **Automatic** uses edge-directed spatial bob on progressive displays and preserves fields if the current display mode reports interlaced. **Deinterlace (Field Rate)** presents both temporal fields when display cadence permits. **Preserve Fields (Weave)** keeps the complete source picture. There is no temporal lookahead or future-frame delay. Spatial interpolation can soften fine vertical detail; weaving on a progressive display can show combing.
- Top-field-first follows the OMT convention. Bottom-field-first is selectable for a sender requiring it. AppKit/Metal **does not guarantee field-synchronized native interlaced scanout**. The app detects an already active interlaced mode but does not force display modes or claim broadcast reference-output timing.
- FPA1 planar Float32 audio, 1–32 channels, 8–384 kHz, subject to Core Audio route support. Source sample rate/channel count are preserved into `AVAudioEngine`; its mixer performs the conversion required by the actual output device. Stereo 44.1 kHz and 48 kHz are exercised with the SDK. No microphone permission is needed.

Each full-quality receiver uses one sender-timestamp-to-host-clock mapping for video and audio, with a 60 ms playout budget. Bounded video admission keeps at most eight pictures / 128 MiB, plus the current and in-flight GPU surfaces; oversized individual supported frames can occupy one slot. Audio admission is capped at 300 ms and scheduled audio at 350 ms. Late video is discarded rather than accumulating latency. These are buffering policies, **not measured end-to-end latency or A/V-sync certification**.

## Optional OMT Discovery Server

Enter a URL such as `omt://server.example:6399` in Settings, press Apply, then relaunch. Empty means ordinary Bonjour. The official SDK owns server discovery and media connection behavior. This SDK initializes discovery globally, so changes require a new app process; the UI explicitly reports that requirement. Existing receivers continue using the current configuration until relaunch.

Configuration and SDK storage are app-specific. The app does not edit `~/.OMT/settings.xml` or eucaly's settings. If local-network access was denied, allow OMTReceiver under **System Settings → Privacy & Security → Local Network**, then relaunch.

## Testing with eucaly

1. Run eucaly on this Mac or another Mac on the network.
2. Open **Settings → Outputs → Add Output → OMT Output**.
3. Set a source name and workspace, enable it, then explicitly **Start** or **Show Slides**. Merely browsing or enabling an output does not start its sender.
4. Click its live thumbnail in OMTReceiver. Check moving video and sound, then lyrics or another keyed graphic with the checkerboard background to inspect alpha.
5. Open a second receiver; mute one when showing the same source. Exercise fullscreen on each display, Escape, sender Stop/Start, and a disconnected display.

The application is generic: it accepts any compatible OMT sender, including official OMT tools and OBS's OMT plugin. eucaly supplies no special receiving protocol.

An optional native integration test accepts an **already running isolated eucaly fixture**, expecting eucaly's documented 1920×1080p30 Rec.709 / stereo 48 kHz format and a source name containing `eucaly Production Stress`:

```sh
TEST_RUNNER_OMT_EUCALY_TEST_ADDRESS=omt://127.0.0.1:ACTUAL_PORT \
  xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiver \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:OMTReceiverTests/EucalyIntegrationTests \
  CODE_SIGN_IDENTITY=- test
```

Use eucaly's existing `scripts/test-omt-production-stress.py` fixture with its required explicit deadline and unique output/control directories if automated source setup is wanted. Its generated media exercises the actual accepted Current → compositor → helper → OMT SDK path without opening an operator library or native projection. Discover the actual test-owned helper's TCP listener; do not assume port 6400. The normal receiver tests create their own small official-SDK sender and require no eucaly checkout.

## SDK replacement and distribution

`Vendor/OMT` contains SDK 1.0.0.19 from the existing eucaly integration: an unmodified pinned-upstream NativeAOT arm64 transport, the original VMX codec, C header, MIT/NativeAOT notices and provenance. No standalone .NET runtime is needed. See `Vendor/OMT/provenance.json`, `BUILDING.md` and `PATCHES.md` for exact hashes/source commits and the inactive historical patches.

The documents inside `Vendor/OMT` are preserved provenance from eucaly's sender integration. Their helper process, fixed output format and eucaly commands describe that sender. **OMTReceiver loads the bundled SDK in its own process**, owns receiver/discovery workers, and accepts the source formats described above. Use this README for receiver behavior; the historical documents and their recorded hashes remain unchanged. CI verifies the pinned SDK files before building and checks that regenerating the Xcode project produces no changes. Test result bundles and native build/test logs are retained as validation artifacts, including on failed runs.

For another ABI-compatible SDK, arrange `include/libomt.h`, `lib/libomt.dylib` and `lib/libvmx.dylib` beneath one folder, then set the **OMT_SDK_ROOT** Xcode build setting to its absolute path. For example:

```sh
xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiver \
  -configuration Release OMT_SDK_ROOT=/absolute/path/to/SDK \
  build
```

The embed phase copies both libraries to `Contents/Frameworks/OMT`, signs the copies using the app's identity and copies SDK notices into Resources. The bridge loads **only those bundle paths**, with `libvmx` loaded before `libomt`. It reports missing libraries/symbols in the UI. The application can still show its built-in test pattern if the network runtime fails.

For distribution, use `make release` after committing and pushing to the separate macOS repository, **sukujgrg/OMTReceiver-macOS**, with a passing Validate run on that exact `main` commit. The release pipeline builds with Developer ID, verifies the app/Sparkle/OMT signatures, notarizes and staples, signs the update feed, then creates the tag and GitHub release. It preserves resumable work under `build/release/`; it never force-pushes tags or overwrites published assets. See [the release guide](docs/releasing.md).

## Self-updates

**OMTReceiver → Check for Updates…** and **Settings → Updates** use Sparkle's native dialogs. Automatic checks are configurable; scheduled checks show a toolbar reminder without interrupting fullscreen playback. Download, installation and restart require user action. Restart follows normal receiver/discovery cleanup. The updater is app-owned and shared across receiver windows.

Both feed and update archives require Ed25519 signatures. OMTReceiver has a separate persistent Keychain signing identity (`com.suku.OMTReceiver-macOS`), and its public key is in the source Info.plist template. The eucaly private key is not reused. The [published macOS release](https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest) provides the [signed appcast](https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest/download/appcast.xml) used by online update checks.

## Website

The product site is static HTML/CSS in `site/`, hosted at [sukujgrg.github.io/OMTReceiver-macOS](https://sukujgrg.github.io/OMTReceiver-macOS/). It has no build step, package dependencies, JavaScript, or third-party analytics. Download links use GitHub's [latest release page](https://github.com/sukujgrg/OMTReceiver-macOS/releases/latest), so new app releases need no website version changes.

```sh
make test-site                     # offline links, assets, navigation, and metadata checks
python3 -m http.server 8000 --directory site
```

Open `http://localhost:8000` for a local preview.

The **Publish website** workflow uploads `site/` directly after site changes reach `main`, or when run manually. GitHub Pages must use **GitHub Actions** as its publishing source. The standard `github-pages` environment allows deployments from `main`; the workflow uses a read-only build token and deployment-only Pages/OIDC permissions. Website publishing does not require Apple or Sparkle signing credentials and does not modify the Sparkle feed or release archives.

## Structure

- `Application/`: AppKit entry point, menu ownership, shared Sparkle updater and preferences/display identities.
- `Transport/`: SDK loader/C bridge, Bonjour + server discovery, independently canceled receiver workers and copied/validated media.
- `Playback/`: shared playback clock, bounded Metal renderer/shader, field handling and bounded Core Audio playback.
- `Interface/`: independent window/source controllers, Settings and dedicated fullscreen lifecycle.
- `OMTReceiverTests/`: model, malformed-frame/lifetime, SDK loopback, native UI and GPU readback checks.

Only SDK frame memory copied before the next receive call crosses the transport boundary. Cancellation fences admission before playback is cleared; queued status callbacks carry a generation. Closing a window asynchronously retires its SDK instance. Quit waits for every receiver and discovery poll before the one process-wide SDK shutdown.

Original application code is MIT licensed. Third-party notices are retained under `Vendor/OMT/LICENSE.txt`. Open Media Transport and related marks belong to their owners; this is an independent receiver.

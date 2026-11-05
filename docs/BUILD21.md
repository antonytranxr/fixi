# Normal Fixi build 21

**Version 1.0 (21)** is the normal camera-enabled app immediately before the recording demo was created. This repository publishes that app for source review and testing with your own provider accounts.

Build 21 does not contain the later recording mode, supplied vehicle photos, or bundled engine-filter reference images. It connects directly to Meta and OpenAI; there is no shared hosted backend.

## User flow

Welcome → photo and spoken/text details → confirmation → tools and parts → full checklist → step → next unfinished step → completion.

- **Glasses** starts continuous foreground listening and live-view intent after permissions. A wake phrase is not required.
- **Mute mic** and **Pause camera** are independent controls. Backgrounding stops the session; return to the app and choose Glasses to resume.
- **Complete** marks the active step and opens the next unfinished step. **Back** returns to the checklist without completing it.
- Steps can use accepted targets from saved photos, an attributed web example, or instructions alone. Entering a step without an accepted image can make one quiet, bounded attempt to use a fresh frame when the glasses camera is enabled.
- Native display focus, scrolling, and pinch select controls. Experimental raw swipe-edge page navigation is disabled in this baseline.
- The three phone layouts share the same project state and actions. Choose **Menu → Compare designs** to switch.

## Local build and device setup

Requirements:

- macOS and an Xcode/Swift toolchain supported by [Meta Wearables DAT](https://github.com/meta/meta-wearables-dat-ios).
- An iPhone running **iOS 17.2 or later** for the live app.
- Meta Ray-Ban Display with the Meta companion app and the required developer access for the glasses experience.
- Apple signing and the relevant Meta app registration for your distribution method.

The project pins DAT **1.0.1**. Generate and open it:

```sh
FIXI_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
FIXI_BUNDLE_ID=com.yourteam.fixi \
python3 scripts/generate-project.py
open Fixi.xcodeproj
```

Select the Fixi scheme and your iPhone. `Config/App.xcconfig` supplies the shared settings. Keep machine-specific registration overrides in ignored `Config/Local.xcconfig`. A different bundle identifier must match your Meta registration. The original developer-mode configuration is not a substitute for distribution approval.

Pair the glasses in the Meta companion app and enable the appropriate developer mode. In Fixi, choose **Connect through Meta AI**, approve registration, then **Start glasses session**. This starts the display session; **Glasses** or **Live view** requests camera permission when needed. Follow the phone's permission prompts. First-time system dialogs cannot be approved by speaking to Fixi.

Use **Menu → Audio output** to select the glasses, then **Test sound**. The app rejects ineligible output routes rather than intentionally playing narration through the phone speaker. Bluetooth route eligibility does not identify a specific accessory; select the actual glasses.

### Provider configuration

For live analysis, use your own provider accounts. In **Menu → Settings** on the phone:

1. Enter a **Meta Model API key** under **Repair assistant · Meta**, then choose **Save Meta key**. It needs access to `muse-wonder-1.0` for intake, repair plans, visual targets, and ordinary repair questions.
2. Enter an **OpenAI API key** under **Voice & source lookups · OpenAI**, then choose **Save OpenAI key**. It needs access to the configured Realtime narration and Responses models for speech, web lookups, and online examples. See the [provider table](ARCHITECTURE.md#provider-roles).

The keys use separate device-only Keychain entries. Use **Forget Meta key** or **Forget OpenAI key** to remove them. Provider usage is billed to your accounts. No maintainer credentials are included. Never put keys in source files, signing settings, screenshots, issues, or Git commits.

### Offline previews

From the welcome screen, choose **Menu → Try an example**, or add `--demo` to the scheme's launch arguments. This loads a local, labeled three-step cabinet-hinge example and bypasses AI analysis. You can open steps, inspect image markers, and complete the checklist without keys or glasses. Return to a new project to try live analysis.

For a specific screen, add Debug preview arguments:

```text
--preview-screen=checklist
--preview-style=focus
```

Available styles are `focus`, `flow`, and `guide`. Preview screens include `welcome`, `capture`, `confirmation`, `parts`, `checklist`, `step`, `thinking`, `full-photo`, `live-view`, and `live-answer`. Preview state is local, labeled, and synthetic; it makes no provider calls or camera captures.

## Validation

Build 21 was validated on **November 4, 2026**:

| Check | Result |
| --- | --- |
| Offline logic suite | **431 tests, 0 failures** |
| Frozen source comparison | **59 production/test files matched** |
| Signed iPhone compilation | Passed; no compiler warnings |
| Development signature | Verified |
| Device installation and normal launch | Verified; installed version 1.0 (21) |

**Publication check, November 4, 2026:** the clean public checkout also passed a fresh unsigned `xcodebuild` for a generic iOS Simulator destination (`BUILD SUCCEEDED`). This was a compilation check, not a rerun of the 431-test baseline or a simulator UI or hardware trial. The [validation record](build21-validation.json) keeps these results separate.

The SDK-free test harness copies production logic and substitutes the glasses adapter. It excludes native SDK transport, the app entry point, SwiftUI views, physical microphone and speakers, and hardware gestures. It does not read saved API keys or send live AI requests.

The suite covers project intake and confirmation, bounded requests, response validation, exact photo binding, image geometry, voice-action routing, progress, cancellation, next-unfinished navigation, and stale callback handling. The new automatic camera-target tests use controlled frame timing and fakes.

No new physical glasses/camera trial, live provider request, or simulator UI review was performed for build 21. The README images are historical offline simulator previews from builds 18 and 20. They show the existing interface, not evidence of real-world repair accuracy.

Known evaluation boundaries include provider access, exact vehicle or part compatibility, image-target accuracy, physical audio routing, wearer versus bystander speech, gesture focus, camera/microphone coexistence, and battery use. The SDK speech path does not provide app-level wearer authentication. Mute the microphone during nearby conversations.

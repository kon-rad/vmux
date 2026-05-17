# vmux — visionOS Spatial SSH & Agent Workspace

> **For the Ralph loop:** `ralph.sh` runs a fresh Claude on every iteration. Pick the first unchecked task in **§7 Task List**, implement it end-to-end, verify against its **Acceptance** block, commit, append the task ID to `progress.txt`, then exit. Do **one task per iteration**. Tasks are ordered so dependencies resolve naturally — do not skip ahead.

---

## 1. Goal

An Apple Vision Pro app that gives you a `cmux`-style workspace for SSH-driven AI agents. You create a project (= one SSH server), spawn terminal tabs (= shells on that server), drag each tab anywhere around you in 3D space, and drive any tab by **looking at it and speaking**. The whole scene sits inside an AI-generated 360° panorama you create from the Settings panel.

The MVP is one developer's tool, one shot, simplest viable stack.

## 2. Non-goals (explicitly cut from MVP)

- Multi-user / collaborative sessions
- SFTP / file-tree viewer / code inspector windows
- LLM-call trace inspector
- Log filtering UI
- Hand-gesture customization beyond the visionOS defaults
- iPad / macOS port (visionOS only)
- Passphrase-protected SSH keys (user decrypts before pasting)
- OAuth or 2FA on SSH
- Multiple simultaneous panoramas / live skybox switching mid-session
- Background app refresh / agent monitoring while app is closed

## 3. Locked tech stack

| Concern | Choice | Notes |
|---|---|---|
| OS | visionOS 2.0+ | Min deployment. |
| Language | Swift 6 | Strict concurrency enabled. |
| UI | SwiftUI | All views. |
| 3D | RealityKit | Skydome only. |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) | Built on Apple's SwiftNIO SSH. Use `SSHClient` + `withSSHShell` or equivalent. |
| Terminal emulator | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Wrap `TerminalView` (UIKit) with `UIViewRepresentable`. If SwiftTerm fails to build for visionOS, fall back to its iOS target via `#if os(visionOS)` shim — do **not** swap libraries. |
| Speech-to-text | **Google Gemini Live API** over WebSocket via `URLSessionWebSocketTask` (built-in) | Higher accuracy than Apple Speech for technical commands and multi-word identifiers. Default model `gemini-2.5-flash` (override to `gemini-2.5-pro` in Settings for max quality, or to current `*-flash-live-preview` variant if Google renames). No third-party SDK — raw JSON over the documented bidi WebSocket. |
| Audio capture | `AVAudioEngine` + `AVAudioConverter` (built-in) | Tap input node, downsample to 16-bit PCM little-endian, 16 kHz, mono — the exact format Gemini Live requires (MIME `audio/pcm;rate=16000`). |
| Persistence | SwiftData (`@Model`) | Container in `vmuxApp`. |
| Secrets | Keychain Services (built-in) | Wrap in a small `KeychainService` helper. No third party. |
| Image API | OpenAI Images API via `URLSession` | Endpoint `POST https://api.openai.com/v1/images/generations`, model `gpt-image-2`, size `2048x1024`, `response_format: "b64_json"`. No SDK. If `gpt-image-2` returns 404, fall back to `gpt-image-1` and surface a warning; do not silently swap models. |
| Networking | `URLSession` async | No Alamofire. |
| Testing | XCTest + Swift Testing where ergonomic | Unit tests live in `vmuxTests`. |

Do **not** add other dependencies without changing this section first.

## 4. Architecture

### 4.1 Scene graph

```
@main vmuxApp
├── WindowGroup("sidebar")        // small control panel
│   └── SidebarView
├── WindowGroup("settings")       // opened from sidebar bottom-left
│   └── SettingsView
├── WindowGroup("terminal", for: Tab.ID)   // one window per open tab
│   └── TerminalWindowView(tabID:)
└── ImmersiveSpace("environment") // mixed style, always open after first launch
    └── SkydomeView
```

- visionOS provides window dragging / 3D positioning natively. Do not build positioning logic.
- Mixed immersion style so SwiftUI windows float in front of the skydome.

### 4.2 Data model (SwiftData)

```swift
@Model final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int                      // default 22
    var username: String
    var authType: String               // "password" | "privateKey"
    var keychainRef: String            // identifier passed to KeychainService
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Tab.project) var tabs: [Tab]
}

@Model final class Tab {
    @Attribute(.unique) var id: UUID
    var title: String                  // user-editable; default "Tab N"
    var project: Project?
    var lastActivityAt: Date
    var isRunning: Bool                // updated by ActivityMonitor
    var createdAt: Date
}

@Model final class AppSettings {       // single-row
    var displayName: String
    var openAIKeychainRef: String      // "" if unset
    var geminiKeychainRef: String      // "" if unset
    var geminiModel: String            // default "gemini-2.5-flash"
    var activePanoramaFilename: String?  // file in Documents/panoramas/
    var idleThresholdSeconds: Int      // default 3
}
```

Credentials never live in SwiftData — only the Keychain reference does.
Panoramas live at `<Documents>/panoramas/<uuid>.png`.

### 4.3 Services (all `@MainActor` unless noted)

| Service | Responsibility |
|---|---|
| `KeychainService` | `save(secret:for:)`, `load(for:) -> String?`, `delete(for:)`. Uses `kSecClassGenericPassword` with `service = "vmux"`. |
| `SSHConnectionManager` | One `Citadel.SSHClient` per `Project`. Lazy connect. Vends fresh shell channels. Reconnect on disconnect with backoff. |
| `TerminalSession` | Owns one shell channel + one `SwiftTerm.Terminal`. Pumps bytes both directions. Publishes `lastByteAt: Date`. |
| `SpeechCoordinator` | Singleton. Observes `FocusStore.focusedTabID`. Owns one `AVAudioEngine` + one `GeminiLiveSession` at a time. Publishes `partialTranscript: String`. On 1.0s pause OR detected keyword "send"/"enter", writes `transcript + "\r"` to the focused `TerminalSession` and resets buffer. |
| `GeminiLiveClient` / `GeminiLiveSession` | Wraps `URLSessionWebSocketTask` against `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<KEY>`. Sends setup message, then streams `realtimeInput.audio` frames (base64 PCM16 16kHz). Reads `serverContent.inputTranscription.text` events and publishes them as partial transcripts. Handles reconnect with exponential backoff. |
| `AudioFormatConverter` | Converts AVAudio buffers from the input node's native format to 16-bit PCM, 16 kHz, mono, little-endian. One `AVAudioConverter` per session. |
| `FocusStore` | `@Observable`. Holds `focusedTabID: UUID?`. Updated by `TerminalWindowView.onHover`. |
| `ActivityMonitor` | One per `Tab`. Subscribes to its `TerminalSession.lastByteAt`. 500ms timer; when `now - lastByteAt > idleThreshold` AND tab received bytes since last "done" fire, sets `tab.isRunning = false` and triggers a one-shot system sound. |
| `PanoramaStore` | Lists / saves / deletes PNGs in `Documents/panoramas/`. Publishes `activeImage: UIImage?`. |
| `OpenAIImageClient` | One async function `generatePanorama(prompt:, apiKey:) async throws -> Data` (PNG bytes). |

### 4.4 Speech flow

1. `TerminalWindowView` attaches `.onHover { hovering in if hovering { FocusStore.shared.focusedTabID = tabID } }`. Focus is **sticky** — does not clear on hover-out; only changes when another tab is hovered.
2. `SpeechCoordinator` observes `focusedTabID`. On change:
   - Request mic permission (first time only).
   - Tear down any existing `GeminiLiveSession` (closes the WebSocket and clears `partialTranscript`).
   - Open a new `GeminiLiveSession` to the Gemini Live WebSocket. Send the setup message:
     ```json
     {
       "config": {
         "model": "models/<configured-model>",
         "responseModalities": ["TEXT"],
         "inputAudioTranscription": {},
         "systemInstruction": { "parts": [{ "text": "Transcribe the user's spoken words verbatim. Do not respond. Do not paraphrase. Output exactly what was said." }] }
       }
     }
     ```
   - Start `AVAudioEngine`. Install a tap on the input node. For each buffer, convert to PCM16 / 16 kHz / mono via `AudioFormatConverter`, base64-encode, send as `{"realtimeInput":{"audio":{"data":"<b64>","mimeType":"audio/pcm;rate=16000"}}}`.
3. As `serverContent.inputTranscription.text` events arrive, **append** them to `partialTranscript` (Gemini sends incremental fragments, not cumulative strings). `TerminalWindowView` overlays a translucent pill `🎙 "<partial>"` on its focused window.
4. Commit trigger: no new transcript fragment for ≥ 1.0 s **or** the buffer's trailing words match " send" / " enter" (case-insensitive). On commit, strip the trigger word, write `text + "\r"` to the **currently** focused tab's `TerminalSession` (re-read `FocusStore.focusedTabID` at commit time, not at speech-start time), clear `partialTranscript`. The WebSocket stays open between commits — no reconnect per utterance.
5. Focus change mid-utterance: cancel the current session (closing the socket), discard any in-flight partials, open a new session bound to the new focus. The discarded partial is **not** sent to either tab.

### 4.5 Agent-done flow

- `TerminalSession.lastByteAt` updates on every byte received from the shell.
- `ActivityMonitor` fires `tab.isRunning = false` once when idle threshold elapses after activity. Plays `SystemSoundID(1004)` (subtle "tweet"). Sidebar tab row shows a green dot for 5s then steady idle indicator.
- When new bytes arrive, `isRunning = true` again. Subsequent done events allowed.

### 4.6 360 panorama flow

- **Generate**: SettingsView → user enters prompt → tap "Generate". App wraps:
  ```
  <user prompt>. Fully immersive 360-degree equirectangular panorama, seamless horizontal wrap, no visible seam, evenly lit, no text, no watermarks.
  ```
  POSTs to OpenAI Images API. Decodes `b64_json`. Writes to `Documents/panoramas/<uuid>.png`. Sets `activePanoramaFilename`.
- **Display**: `SkydomeView` creates a `MeshResource.generateSphere(radius: 30)`, flips normals (or applies `.front` cull off + inverted UVs), applies `UnlitMaterial` with the active PNG as `baseColor.texture`. Reloads when `activePanoramaFilename` changes.

## 5. UI spec

### 5.1 Sidebar window

- Size: ~340pt wide, ~640pt tall (visionOS default-ish small panel).
- Top section: **Projects** header + list. Each row: name. Tap = select. Long-press / context menu = rename / delete. `+ New Project` row at bottom of section.
- Middle section: **Tabs in <selected project>** list. Each row: title, status dot (gray idle / amber running / green just-done). Tap = open/focus that tab's window. Swipe / context menu = close. `+ New Tab` at bottom.
- Bottom: ⚙ **Settings** button (bottom-left corner per requirement).

### 5.2 Settings window

- Sections:
  1. **Profile** — display name field.
  2. **OpenAI API key** — secure field, stored in Keychain. "Test" button does a `GET /v1/models` call and shows ✓/✗.
  3. **Gemini API key + speech model** — secure field for the Gemini API key, stored in Keychain. Picker for `geminiModel`: options `gemini-2.5-flash` (default), `gemini-2.5-pro`, and a free-text "custom model" field for Google-introduced variants (e.g. `gemini-2.5-flash-live-preview`). "Test" button opens a Live WebSocket, sends the setup message, waits for the first `setupComplete` server message, then closes — shows ✓ on success / ✗ with HTTP or close-code on failure.
  4. **360 Environment** — prompt textarea (multi-line, ≤ 32k chars), "Generate Panorama" button (disabled if no OpenAI key), progress indicator during call, grid of saved panoramas with thumbnails (~120pt). Tap = set active. Long-press = delete. Active one has a check overlay.
  5. **Agent detection** — idle threshold slider (1–10s, default 3).

### 5.3 Terminal window

- Each tab opens as its own `WindowGroup` instance, value = `Tab.ID`.
- Body: SwiftTerm view filling the window. Title bar shows tab title + project name.
- Overlay (top-center, when focused): `🎙 "<partial transcript>"` translucent pill. Fades in on focus, out 2s after last partial.
- Border glow when `FocusStore.focusedTabID == self.tabID` (subtle blue tint).

## 6. File layout

```
vmux/                              # Xcode project root
├── vmux.xcodeproj
├── vmux/                          # app target
│   ├── vmuxApp.swift              # @main + scene graph
│   ├── Models/
│   │   ├── Project.swift
│   │   ├── Tab.swift
│   │   └── AppSettings.swift
│   ├── Services/
│   │   ├── KeychainService.swift
│   │   ├── SSHConnectionManager.swift
│   │   ├── TerminalSession.swift
│   │   ├── SpeechCoordinator.swift
│   │   ├── GeminiLiveClient.swift           # WebSocket + setup + frame protocol
│   │   ├── AudioFormatConverter.swift       # AVAudio → PCM16 16kHz mono
│   │   ├── FocusStore.swift
│   │   ├── ActivityMonitor.swift
│   │   ├── PanoramaStore.swift
│   │   └── OpenAIImageClient.swift
│   ├── Views/
│   │   ├── SidebarView.swift
│   │   ├── SettingsView.swift
│   │   ├── TerminalWindowView.swift
│   │   ├── SkydomeView.swift
│   │   └── Components/
│   │       ├── NewProjectSheet.swift
│   │       └── TranscriptPill.swift
│   ├── SwiftTerm+SwiftUI.swift    # UIViewRepresentable bridge
│   └── Info.plist                 # privacy strings
├── vmuxTests/
├── PRD.md
├── progress.txt
└── ralph.sh
```

## 7. Task list

> Format: every task is `- [ ] T-NNN — Title`, followed by **Why**, **Do**, **Acceptance**, **Depends on**. Implement the **first unchecked task** only. After completion, flip `[ ]` → `[x]` and append `T-NNN` to `progress.txt`.

### Phase 0 — Scaffold

- [x] **T-001 — Create Xcode visionOS project**
  - **Why**: Need the project file to add code to.
  - **Do**: Create `vmux.xcodeproj` in repo root. App target name `vmux`, bundle id **`com.konradgnat.vmux`**, platform `visionOS 2.0`, interface `SwiftUI`, lifecycle `SwiftUI App`, language `Swift 6`. Add test target `vmuxTests` (bundle id `com.konradgnat.vmux.tests`). Apple Development Team: **`DHB5JNF8ZW`** (Konrad Gnat). Codesign style: Automatic; `CODE_SIGNING_ALLOWED: YES`.
  - **Acceptance**: `xcodebuild -scheme vmux -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build` succeeds. Project opens in Xcode without warnings.
  - **Depends on**: —

- [x] **T-002 — Add SwiftPM dependencies**
  - **Why**: Lock the only two third-party packages we'll use.
  - **Do**: Add `Citadel` (`https://github.com/orlandos-nl/Citadel`, latest 1.x) and `SwiftTerm` (`https://github.com/migueldeicaza/SwiftTerm`, main or latest tag) to `vmux` target via SwiftPM in Xcode. Commit `Package.resolved`.
  - **Acceptance**: `import Citadel` and `import SwiftTerm` compile in a temporary file inside `vmux/`. Build still passes for visionOS simulator.
  - **Depends on**: T-001

- [x] **T-003 — Privacy & entitlements**
  - **Why**: Mic capture requires an Info.plist string or the app crashes on first use. Apple's Speech framework is **not** used (Gemini Live API replaces it), so `NSSpeechRecognitionUsageDescription` is intentionally omitted.
  - **Do**: Add to `Info.plist`:
    - `NSMicrophoneUsageDescription` = "vmux uses the microphone to dictate commands into your focused terminal via Google Gemini."
    - Default ATS is fine for `api.openai.com` and `generativelanguage.googleapis.com` (both HTTPS / WSS); no override needed.
  - **Acceptance**: `plutil -lint vmux/Info.plist` passes. Mic string present. No Speech framework string.
  - **Depends on**: T-001

- [x] **T-004 — SwiftData models + container**
  - **Why**: Persistence layer for projects/tabs/settings.
  - **Do**: Implement `Project`, `Tab`, `AppSettings` per §4.2. Wire `ModelContainer(for: Project.self, Tab.self, AppSettings.self)` in `vmuxApp` via `.modelContainer(...)`. On first launch create a single `AppSettings` row with defaults (`displayName = ""`, `idleThresholdSeconds = 3`).
  - **Acceptance**: Unit test creates a Project + Tab in an in-memory container, fetches them back, asserts cascade-delete removes child tabs. App launch creates exactly one `AppSettings` row.
  - **Depends on**: T-001

- [x] **T-005 — Scene graph stub**
  - **Why**: Get all windows reachable so later tasks can fill them in.
  - **Do**: Define all four scenes in `vmuxApp.swift` per §4.1. Each view is a placeholder `Text(...)`. The terminal `WindowGroup(for: Tab.ID.self)` uses `value: tabID` to open. Inside the sidebar placeholder, add three temporary buttons: "Open Settings" (calls `openWindow(id: "settings")`), "Open Terminal" (calls `openWindow(id: "terminal", value: UUID())`), and "Toggle Environment" (calls `openImmersiveSpace(id: "environment")` / `dismissImmersiveSpace()`). These buttons are deleted in later tasks (T-007, T-019) once real triggers exist.
  - **Acceptance**: App launches in visionOS simulator. Sidebar window appears with three temporary buttons. Each button opens its respective scene.
  - **Depends on**: T-001

### Phase 1 — Sidebar, Projects, Settings shell

- [x] **T-006 — KeychainService**
  - **Why**: Needed before any auth-storing UI.
  - **Do**: Implement `save(_ secret: String, for ref: String)`, `load(for ref: String) -> String?`, `delete(for ref: String)` using `SecItemAdd/Copy/Delete` with `kSecClassGenericPassword`, `kSecAttrService = "vmux"`, `kSecAttrAccount = ref`.
  - **Acceptance**: Unit test round-trips a secret. Delete removes it. Loading missing returns nil.
  - **Depends on**: T-001

- [x] **T-007 — SidebarView shell**
  - **Why**: Primary navigation.
  - **Do**: Build sections per §5.1. Projects list reads from SwiftData `@Query`. Selecting a project sets a `@State` selected ID. Tab list filters by selected project. `+ New Project` and `+ New Tab` buttons wired to no-op handlers for now (real sheets/openers in T-008, T-012). Settings button at bottom-left opens settings window via `@Environment(\.openWindow)`. **Remove** the three temp buttons added in T-005.
  - **Acceptance**: With manually-inserted test data, sidebar shows projects + tabs. Settings button opens the settings window. The T-005 temp buttons are gone.
  - **Depends on**: T-004, T-005

- [x] **T-008 — NewProjectSheet**
  - **Why**: Create projects.
  - **Do**: Sheet from sidebar `+ New Project`. Fields: name, host, port (default 22), username, auth picker (password / private key), secure input for the secret. On save: generate UUID `keychainRef`, store secret via `KeychainService`, insert `Project`.
  - **Acceptance**: Adding a project persists across app relaunch. Secret stored under `vmux/<keychainRef>` in Keychain. Form validates: name non-empty, host non-empty, port 1–65535.
  - **Depends on**: T-006, T-007

- [x] **T-009 — SettingsView (profile + OpenAI key + Gemini key + idle threshold)**
  - **Why**: Lay the groundwork before generation UI and speech.
  - **Do**: Sections 1, 2, 3, and 5 from §5.2. Display-name TextField bound to `AppSettings.displayName`. OpenAI key stored via `KeychainService` under `AppSettings.openAIKeychainRef` (generate UUID once, then reuse). "Test OpenAI" button performs `GET https://api.openai.com/v1/models` with `Authorization: Bearer <key>` → ✓/✗. Gemini key stored under `AppSettings.geminiKeychainRef`. Model picker (`gemini-2.5-flash` default, `gemini-2.5-pro`, or custom string) bound to `AppSettings.geminiModel`. "Test Gemini" button is a lightweight check: `GET https://generativelanguage.googleapis.com/v1beta/models?key=<key>` returns 200 → ✓. Idle-threshold slider bound to `AppSettings.idleThresholdSeconds`, range 1…10, snaps to integer.
  - **Acceptance**: Display name, both keys, model selection, and slider value all persist across relaunch. Both Test buttons surface success/failure correctly for valid/invalid keys.
  - **Depends on**: T-006, T-005

### Phase 2 — SSH + Terminal

- [x] **T-010 — SSHConnectionManager**
  - **Why**: Central place to share a `Citadel.SSHClient` across tabs of one project.
  - **Do**: `actor SSHConnectionManager` keyed by `Project.id`. `func client(for: Project) async throws -> SSHClient` — connects if needed using stored auth (password or pasted private key). On unexpected disconnect, mark dead and reconnect on next request.
  - **Acceptance**: Integration test (skippable without `VMUX_TEST_HOST` env) connects to a local SSH server, runs `echo ok`, gets "ok". Manual: connecting to a known server from the app does not throw.
  - **Depends on**: T-002, T-008

- [x] **T-011 — TerminalSession**
  - **Why**: Bridge SSH bytes ↔ terminal emulator.
  - **Do**: Class owning one Citadel shell channel and one `SwiftTerm.Terminal`. Forward shell output bytes into `terminal.feed(...)`. Forward user input from terminal into shell. Expose `send(_ data: Data)` for the speech coordinator. Publish `lastByteAt: Date` on every received chunk.
  - **Acceptance**: Unit test: feed bytes into a stubbed channel, assert terminal buffer contains them; calling `send` writes bytes to the stub.
  - **Depends on**: T-010

- [x] **T-012 — SwiftTerm SwiftUI bridge + TerminalWindowView**
  - **Why**: Render the terminal in a window.
  - **Do**: `UIViewRepresentable` wrapping SwiftTerm's `TerminalView`. `TerminalWindowView(tabID:)` looks up the `Tab` in SwiftData, lazily creates/fetches a `TerminalSession` from a `@MainActor` `TerminalSessionRegistry` (one per `Tab.id`), embeds the bridge view. Closing the **window** (X button) does **not** kill the session — it remains in the registry so reopening continues from where it was. Closing the **tab from the sidebar** (swipe/context-menu delete) DOES tear down: kill the session, remove from registry, delete the `Tab` from SwiftData, close any open window for that ID via `dismissWindow(id:value:)`. Sidebar `+ New Tab` inserts a new `Tab` and calls `openWindow(id: "terminal", value: tab.id)`.
  - **Acceptance**: Open a tab against a real SSH server, type commands, see output. Close + reopen the **window** — session continues. Delete the **tab** from sidebar — session ends, window closes, Tab gone after relaunch.
  - **Depends on**: T-011, T-007

- [x] **T-013 — ActivityMonitor + isRunning**
  - **Why**: Required for "detect when agent run finished".
  - **Do**: One `ActivityMonitor` per `Tab`, started in `TerminalSessionRegistry` when a session is first created and stopped when it's torn down. 500ms timer. On every `lastByteAt` change set `tab.isRunning = true` and `tab.lastActivityAt = lastByteAt`. When `Date.now - lastByteAt > AppSettings.idleThresholdSeconds` AND `isRunning == true`, set `isRunning = false`, fire `AudioServicesPlaySystemSound(1004)`, persist the SwiftData change.
  - **Acceptance**: With a tab open running `sleep 5 && echo done`, `isRunning` becomes true, then false ~3s after `done`. System sound audible. `lastActivityAt` updates while the command runs.
  - **Depends on**: T-011, T-012

- [x] **T-014 — Sidebar status dots**
  - **Why**: Surface T-013's signal.
  - **Do**: In `SidebarView`'s tab list, render a dot: gray when `isRunning == false` and `Date.now - lastActivityAt > 5s`, amber when `isRunning == true`, green pulse for the first 5s after `isRunning` transitions true→false.
  - **Acceptance**: Visual: dots reflect state correctly during a sleep-then-echo command.
  - **Depends on**: T-013

### Phase 3 — Speech

- [ ] **T-015 — FocusStore + hover wiring**
  - **Why**: Source of truth for "what am I looking at".
  - **Do**: `@Observable final class FocusStore { static let shared = ...; var focusedTabID: UUID? }`. In `TerminalWindowView`, `.onHover { hovering in if hovering { FocusStore.shared.focusedTabID = tabID } }`. Sticky — never set to nil on hover-out. Apply a subtle blue border modifier when `FocusStore.shared.focusedTabID == tabID`.
  - **Acceptance**: Manual: hovering between two open terminals updates `FocusStore.focusedTabID`. Window with current focus shows a subtle blue border glow.
  - **Depends on**: T-012

- [ ] **T-016a — GeminiLiveClient (WebSocket + setup)**
  - **Why**: Talk to the Gemini Live API over the documented bidi WebSocket using only `URLSessionWebSocketTask`. No SDK.
  - **Do**: Implement `actor GeminiLiveSession` with an `AsyncStream<TranscriptEvent>` output and an `async func sendAudio(_ pcm16: Data)` input. On `init(apiKey:, model:)`, open a `URLSessionWebSocketTask` to `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<apiKey>`. Send the setup JSON from §4.4 step 2 (with the configured model and `inputAudioTranscription: {}` + `responseModalities: ["TEXT"]`). Wait for `setupComplete` from the server before becoming ready. Start a receive-loop task that parses each server frame and, for any `serverContent.inputTranscription.text` value, yields `TranscriptEvent.partial(text)`. `sendAudio` base64-encodes and sends `{"realtimeInput":{"audio":{"data":"<b64>","mimeType":"audio/pcm;rate=16000"}}}`. Provide `close()` to cleanly terminate. Implement exponential backoff reconnect on unexpected close (250 ms → 4 s).
  - **Acceptance**: Unit test against a stubbed `URLSessionWebSocketTask` (or fake URL session) asserts the setup message body is correct and that received `inputTranscription` frames produce `TranscriptEvent.partial` values. Manual: with a real key, opening a session reaches `setupComplete` within 2 s.
  - **Depends on**: T-006, T-009

- [ ] **T-016b — AudioFormatConverter + SpeechCoordinator**
  - **Why**: Connect mic → Gemini → focused tab.
  - **Do**:
    - `AudioFormatConverter`: wraps one `AVAudioConverter` configured from the input node's native format → PCM16, 16 kHz, mono, little-endian. `convert(_ buffer: AVAudioPCMBuffer) -> Data` returns the raw bytes ready to send.
    - `SpeechCoordinator` (singleton, `@MainActor`): owns one `AVAudioEngine` + at most one `GeminiLiveSession`. Observes `FocusStore.focusedTabID`. On change:
      1. Request `AVAudioApplication.requestRecordPermission` if not granted; surface deny via `ErrorBus` (T-025).
      2. Close current `GeminiLiveSession`; reset `partialTranscript = ""`.
      3. If new focus is non-nil and Gemini key + model are configured, open a new `GeminiLiveSession`. Install a tap on `audioEngine.inputNode` that runs each PCM buffer through `AudioFormatConverter` and pushes via `session.sendAudio(...)`. Start the engine.
      4. Consume the session's `TranscriptEvent` stream on the main actor and **append** each partial fragment to `partialTranscript` (Gemini sends incremental fragments, not cumulative).
    - On commit (per T-018), do **not** close the session — only clear the buffer and continue streaming.
  - **Acceptance**: With a focused tab and a valid Gemini key, speaking into the simulator/device mic updates `partialTranscript` within ~500 ms of speech onset. Switching focus closes the old session and opens a new one (verifiable via WebSocket activity in logs or a debug indicator).
  - **Depends on**: T-015, T-003, T-016a

- [ ] **T-017 — Transcript overlay**
  - **Why**: User feedback that speech is being captured.
  - **Do**: `TranscriptPill` view bound to `SpeechCoordinator.partialTranscript`. Shown on the focused `TerminalWindowView` as a top-center translucent rounded rect with 🎙 icon + text. Hides 2s after the last partial.
  - **Acceptance**: Pill appears on the focused window while speaking; matches partial transcript live.
  - **Depends on**: T-016b

- [ ] **T-018 — Commit on pause / keyword**
  - **Why**: Send transcripts to the shell.
  - **Do**: In `SpeechCoordinator`, debounce: if `partialTranscript` has had no new fragment for 1.0 s OR its trailing words match " send" / " enter" (case-insensitive), strip the trigger word and write `text + "\r"` to the **currently** focused tab's `TerminalSession.send(...)` (re-read `FocusStore.focusedTabID` at commit time). Clear `partialTranscript`. **Do not** close or restart the Gemini Live session — the buffer simply resets and the next fragment starts a new utterance.
  - **Acceptance**: Focus a tab, say "list home directory send" → terminal receives `list home directory` + Enter. Saying "echo hello" + 1 s silence → same effect without the trigger word. Two consecutive utterances within the same focused session both commit correctly without reopening the WebSocket.
  - **Depends on**: T-017, T-011

### Phase 4 — 360 environment

- [ ] **T-019 — SkydomeView (immersive space)**
  - **Why**: Render the 360 background.
  - **Do**: `RealityView` inside `ImmersiveSpace("environment")`. Build an `Entity` with `MeshResource.generateSphere(radius: 30)` rendered from the inside (custom mesh descriptor with reversed indices/normals, or invert via a flipped scale on one axis). Apply `UnlitMaterial` with the active panorama texture, or a placeholder gradient PNG bundled in Assets if none active.
  - **Acceptance**: Launching app and entering immersive space shows a panorama background visible behind the windows.
  - **Depends on**: T-005

- [ ] **T-020 — PanoramaStore + reload-on-change**
  - **Why**: Connect Settings choices to the skydome.
  - **Do**: `PanoramaStore` lists PNGs in `Documents/panoramas/`, can save bytes to a uuid filename, can delete. Publishes `activeImage: UIImage?` driven by `AppSettings.activePanoramaFilename`. `SkydomeView` swaps texture when `activeImage` changes.
  - **Acceptance**: Manually copying a PNG into the Documents/panoramas dir and setting `activePanoramaFilename` updates the skydome live.
  - **Depends on**: T-019, T-004

- [ ] **T-021 — OpenAIImageClient**
  - **Why**: Generate panoramas.
  - **Do**: Define `struct GenerationResult { let pngBytes: Data; let warning: String? }`. Implement `func generatePanorama(prompt: String, apiKey: String) async throws -> GenerationResult`. POST `https://api.openai.com/v1/images/generations` with JSON `{"model":"gpt-image-2","prompt":"<wrapped prompt>","size":"2048x1024","response_format":"b64_json","n":1}`. Wrap the prompt per §4.6. Decode `data[0].b64_json` → PNG bytes. If the API returns an error indicating the model name is unknown (HTTP 404 or 400 with `invalid_model` code), retry once with `gpt-image-1` and set `warning = "gpt-image-2 unavailable; used gpt-image-1 (may not be true 360°)"`. If the API returns `invalid_size` for `2048x1024`, retry once with `1024x1024` and append a size warning.
  - **Acceptance**: Unit test against a stubbed `URLProtocol` asserts the request body matches the spec for success, model-fallback, and size-fallback paths. Manual integration with a real key returns a PNG > 100 KB and a nil-or-non-nil warning as appropriate.
  - **Depends on**: T-009

- [ ] **T-022 — Settings: Generate flow**
  - **Why**: Wire the generator into the UI.
  - **Do**: Add §5.2 section 3. "Generate Panorama" calls `OpenAIImageClient`, writes `GenerationResult.pngBytes` to `Documents/panoramas/<uuid>.png` via `PanoramaStore`, sets it active. Show an indeterminate progress view while in flight. Disable button if no API key. Show error alert on failure. If `GenerationResult.warning != nil`, show a non-blocking yellow banner with the warning text above the grid.
  - **Acceptance**: Entering a prompt and tapping Generate produces a new file in the panoramas grid and switches the skydome to it within ~60s. Warnings surface visibly when present.
  - **Depends on**: T-021, T-020, T-009

- [ ] **T-023 — Panorama picker grid**
  - **Why**: Multiple saved panoramas.
  - **Do**: Grid in Settings rendering all panoramas with `Image(uiImage:)` thumbnails (~120pt). Tap = set active. Long-press = delete (with confirm). Active one has a check overlay.
  - **Acceptance**: Generating two panoramas yields two thumbnails. Tapping each switches the skydome. Deleting removes the file and the thumbnail.
  - **Depends on**: T-022

### Phase 5 — Robustness & docs

- [x] **T-024 — SSH disconnect / reconnect UX**
  - **Why**: Servers drop. Sessions must recover gracefully.
  - **Do**: Add `enum SessionStatus { case connecting, connected, disconnected(reason: String) }` to `TerminalSession` as a published property. `SSHConnectionManager` flips all child sessions to `.disconnected` when the underlying client closes. `TerminalWindowView` observes status and, when `.disconnected`, overlays a banner "Disconnected — Reconnect" with a tap target. Tap calls `TerminalSessionRegistry.reconnect(tabID:)` which discards the dead session and creates a fresh one bound to the same `Tab`.
  - **Acceptance**: Kill the SSH server mid-session, banner appears in all affected terminal windows. Restart server, tap reconnect, terminal accepts input again. The same `Tab` row in the sidebar is reused.
  - **Depends on**: T-012

- [ ] **T-025 — Error surfaces**
  - **Why**: Silent failures = unusable app.
  - **Do**: `ErrorBus` (small `@Observable` singleton that publishes the latest error) + a root-level toast/alert overlay. Wire it from: SSH connect failure (with reason), OpenAI failure (with HTTP status + message), Gemini Live failure (WebSocket close code + reason, or HTTP error during the `models` test), Gemini key missing while focus is set on a tab, mic permission denied (with "Open Settings" deep link).
  - **Acceptance**: Deny mic permission → focusing a tab surfaces the deny banner with a Settings link. Bad SSH password → toast on connect attempt. Invalid Gemini key → toast within 2 s of focusing a tab. Force-close Gemini WebSocket from server → toast appears with the close code; reconnect succeeds on its own.
  - **Depends on**: T-010, T-016b, T-021

- [ ] **T-026 — End-to-end manual verification checklist**
  - **Why**: Confirm the whole flow before declaring MVP done.
  - **Do**: Run every check in §8 on visionOS simulator + (if available) device. Record results inline in `progress.txt` as `T-026 VERIFY: <pass/fail> — <note>` per check.
  - **Acceptance**: All §8 checks pass.
  - **Depends on**: T-001 through T-025

- [ ] **T-027 — README quickstart**
  - **Why**: Future-self / collaborator onboarding.
  - **Do**: Write `README.md` covering: what vmux is (2 sentences), build/run, simulator caveats (mic in sim, no real SSH from sim to your laptop, etc.), how to add a project, how to generate a panorama, where data lives (Keychain, Documents).
  - **Acceptance**: A teammate could clone, build, and reach the first successful terminal connection using only the README.
  - **Depends on**: T-026

## 8. End-to-end verification criteria (used by T-026)

A successful MVP passes **all** of these manually:

1. **Project create** — Create a project with valid host/user/password. It appears in the sidebar after relaunch. After relaunch, `KeychainService.load(for: keychainRef)` returns the secret.
2. **Tab spawn** — From a selected project, `+ New Tab` opens a terminal window. Prompt appears within ~3s.
3. **Multi-tab** — Open ≥ 3 tabs on the same project. Each has its own shell (e.g. `echo $$` returns different PIDs).
4. **Spatial positioning** — Drag each tab window to a different position around you (front, left, right). Positions persist while app runs.
5. **Look-to-focus** — Gaze on Tab A → blue border on A, no border on B. Gaze on B → focus moves to B, sticky.
6. **Speech in** — Focus Tab A, say "echo hello send". Terminal A receives `echo hello\n`. Tab B unchanged.
7. **Focus switch mid-speech** — Start speaking into A, switch gaze to B mid-sentence. Speech in flight does not leak into B; B starts fresh recognition.
8. **Pause commit** — Focus a tab, say "ls -la", wait 1s. Terminal receives `ls -la\n` without saying "send".
9. **Agent-done** — Run `sleep 4 && echo done`. Within ~3s of `done` printing, sidebar tab row shows green pulse and system tweet plays.
10. **360 generation** — In Settings, enter prompt "Mountain valley at dawn". Tap Generate. Within ~60s a thumbnail appears in the grid and the skydome shows it.
11. **Panorama switch** — Generate a second panorama. Tap the first thumbnail → skydome reverts to it. Tap second → skydome shows second.
12. **Reconnect** — Stop the SSH server mid-session. Banner appears in tabs. Restart server, tap reconnect, terminal resumes.
13. **Permission denial** — Deny mic when prompted. Focusing a tab surfaces a clear deny banner with a Settings deep link.
14. **Persistence** — Force-quit, relaunch. Projects, tabs (closed), settings, active panorama, **both API keys**, and selected Gemini model all persist. Keychain secrets retrievable.
15. **Gemini reconnect** — Toggle airplane mode for 5 s while a tab is focused. Banner appears via `ErrorBus`. Restoring network: `GeminiLiveSession` reconnects on its own within ~5 s and transcription resumes without user interaction.
16. **No background drain** — Closing all terminal windows does not leave SSH sessions multiplying. Sessions may remain alive for in-foreground reopening, but should not duplicate per close/open cycle. Closing all windows with no focused tab tears down the Gemini Live WebSocket.

## 9. Definition of Done (whole project)

- All tasks T-001…T-027 checked (T-016 is split into T-016a + T-016b).
- `progress.txt` lists every completed task ID in order.
- All §8 criteria pass on visionOS simulator.
- `xcodebuild test -scheme vmux -destination 'platform=visionOS Simulator,name=Apple Vision Pro'` exits 0.
- No `TODO`, `FIXME`, or `fatalError` in shipped code paths.
- No new third-party dependencies beyond Citadel + SwiftTerm.

## 10. Risks & explicit fallbacks

| Risk | Fallback |
|---|---|
| SwiftTerm doesn't compile on visionOS | Use SwiftTerm's iOS source files via `#if os(visionOS)` shim. If still blocked, vendor only `Terminal.swift` (the pure-Swift parser, no UI) and write a minimal `UITextView`-based renderer. Do not swap libraries. |
| `gpt-image-2` model name not yet accepted by API | T-021 retries once with `gpt-image-1` and surfaces a warning. |
| Citadel API surface changes between versions | Pin the version in `Package.resolved`. Bump deliberately. |
| visionOS simulator can't actually use mic | Note in README. Test on device if possible. Speech permission flow still verifiable in sim. |
| OpenAI API does not accept `2048x1024` for chosen model | Fall back to `1024x1024` and warn user that wraparound seam may be visible. |
| `gemini-2.5-flash` doesn't accept the `inputAudioTranscription` config field, or the WebSocket setup returns an error | T-016a logs the server error and falls back to `gemini-live-2.5-flash-preview` automatically. If that also fails, surface the error and disable the speech indicator until the user picks a different model in Settings. |
| Gemini model names change (Google has been renaming these aggressively) | Model is user-editable in Settings (T-009) via a free-text "custom model" field. Default is `gemini-2.5-flash` but any current model id works. |
| Gemini Live WebSocket dropped or rate-limited mid-session | `GeminiLiveSession` reconnect with exponential backoff (250 ms → 4 s). After 5 failed attempts surface a persistent error via `ErrorBus` and stop trying until the user re-focuses a tab. |
| Audio format conversion stutters on device | If the `AVAudioConverter` can't keep up, drop frames rather than blocking the audio thread. Log dropped count. |

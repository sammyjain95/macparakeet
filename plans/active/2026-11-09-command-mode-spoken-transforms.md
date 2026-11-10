# Command Mode — Voice-Driven Transforms on Selected Text

**Status:** IN PROGRESS — core/MVP partially implemented, dev testing blocked on hotkeys
**Date:** 2026-11-09 (updated 2026-11-10)
**ADRs:** Builds on ADR-022 (Transforms — system-wide LLM rewrites on selected text). Consider ADR-026 amendment on approval.
**Lineage:** Based on the detailed TRD provided by the user. Revives the removed F10a "Command Mode" Core on top of the now-shipped Transforms pipeline and BYO-provider LLM layer.
**Supersedes:** The selected-text-rewrite slice of `plans/active/2026-05-voice-command-agent-mode.md` and `plans/active/2026-06-21-spoken-transforms.md`.

---

## Summary

**Command Mode** is a dedicated, explicit mode (separate hotkey, distinct UI state) where the user highlights text in any app, triggers Command Mode, speaks an instruction ("rewrite professionally", "make bullets", "summarize"), and the result replaces the selection.

Key differentiators from Dictation and the previous Spoken Transforms plan:
- **Explicit mode boundary**: Separate hotkey (e.g., `Fn+Option` or double-tap Fn), distinct pill label ("Command"), different color/sound. **Never infer mode from content.**
- **Local-only, fail-closed**: Forces `RoutingLLMClient` to local MLX provider only. No cloud fallback. Blocks non-loopback hosts. Shows persistent "Local only, no network" badge with model name/size.
- **Capture selection first, then listen**: Capture `AppContext` + selection via AX/clipboard *before* recording starts. Command transcript never enters `ClipboardService.pasteText` — only the result is pasted.
- **Two-tier transforms**: Tier 1 = deterministic, instant, no LLM (bullets, case, sort, whitespace, markdown table). Tier 2 = local LLM with constrained prompts, low temp, JSON output validation + retry.
- **Security**: Selected text wrapped in delimiters, labeled as data. Strip/neutralize instruction-like phrases. Validate output (no echo, no "Sure, here is", length checks).
- **Preview + Replace + Undo**: Deterministic = auto-apply + toast + 10s undo. LLM/long selections = non-activating preview panel with Before/After diff + Accept/Retry/Cancel. User setting: Always preview / Auto-apply deterministic only / Auto-apply all.
- **App-aware**: Pass only `category + fieldKind + language hint` to model. Slack = short/warm; Mail/Word/Notion = formal; Xcode/VS Code = comments only; Terminal = refuse; Browser prompt = clear prompt.
- **Performance**: Sequence STT and LLM (unload Parakeet before loading MLX). Cap selection at ~4000 tokens. Use quantized KV, model unload on idle.
- **Privacy hardening**: No selected text/command/result in telemetry/crash logs. No history by default (opt-in with per-app exclusions). Secure field = refuse. No window titles in history.

---

## Scope Boundaries

### In Scope (MVP)
1. One Command hotkey (e.g., `Fn+Option`), one local MLX model (Qwen3-4B), fail-closed local routing
2. Selection capture + AppContext capture (bundle ID, category, fieldKind)
3. 8 deterministic commands + 5 LLM commands:
   - Deterministic: bullets, numbered list, uppercase, lowercase, title case, remove duplicates, sort lines, remove extra whitespace/fix line breaks, markdown table from CSV lines
   - LLM: professional, friendly, concise, formal, bullet points (LLM)
4. Preview + Replace + Undo, command transcript never pasted
5. Local-only badge + model name in pill (e.g., "Qwen3-4B, 2.53 GB")
6. Secure field detection and refusal
7. Content-free telemetry mirroring `transform_executed` / `transform_failed`

### Explicitly Out of Scope (Stays Parked)
- Any action other than rewriting the selection (pressing keys, submitting forms, launching apps, browser automation)
- Screen capture, OCR, or window/AX context beyond selection
- Multi-step agent loops, tool registries, macros, task handoff
- Language-inferred mode switching (mode boundary = hotkey, full stop)
- Chained commands ("make professional AND bullets"), saved custom commands, per-app defaults, typed-command fallback
- Dictation fallback on empty selection

---

## Architecture — Reuse Map

| Concern | Reuse (Shipped Today) | New Glue Needed |
|---|---|---|
| Trigger | `HotkeyTrigger` (new dedicated trigger); `HotkeyManager` hold semantics | A dedicated trigger + settings accessor + conflict validation |
| Selection snapshot | `SelectionCaptureService.captureSelection()` → text + AX element + target | None |
| AppContext | `FocusedAppContextService.currentContext()` | Extend to include fieldKind (text field, code editor, secure field, etc.) |
| Record + transcribe | `DictationService.startRecording` / `stopRecording` (Parakeet) | A thin session that records while held and returns instruction string |
| Tier 1 deterministic | New Swift functions | Implement 8 deterministic transforms |
| Tier 2 LLM | `LLMService.transformStream(text:prompt:)` + `buildTransformMessages` | Feed instruction as `prompt` with constrained system prompt + JSON validation |
| Apply result | `SelectionReplacementService.pasteIntoCurrentFocus` | None |
| Overlay UI | `DictationOverlayController` non-activating panel; existing `SessionKind.command` (`commandSelectedText` / `commandPromptText`) | Wire `.command` to new `CommandModeCoordinator`; add preview panel |
| Orchestration | Pattern of `TransformsCoordinator` / `DictationFlowCoordinator` | New `CommandModeCoordinator`: capture → record → transcribe → transform → replace |
| History | `TransformHistoryRepository` / `transform_history` | New capture-path tag value ("voice-command") |
| Local LLM | `InProcessLLMClient` (MLX), `RoutingLLMClient` | Local-only routing mode in `RoutingLLMClient`; enforce in Command Mode |

---

## Design Decisions and Invariants

1. **Mode boundary = dedicated hotkey, not language inference.** Predictable; plain dictation can never accidentally become a command.
2. **Capture on key-down, before recording starts**, while host app is still frontmost.
3. **No-selection behavior**: Show "Nothing selected" and offer "Use current paragraph" as explicit choice. Do NOT implicitly Cmd+A. Do NOT silently fall through to dictation.
4. **Reversible by construction**: `.pasteIntoCurrentFocus` + Cmd-Z is escape hatch; replace phase is non-cancellable once paste begins.
5. **Selection is data, spoken words are instruction.** Reuse ADR-022's system prompt separation. Wrap selected text in delimiters with explicit data label.
6. **Local-only enforcement**: `RoutingLLMClient` gets a `forceLocalOnly` flag. If local model missing/failed/OOM → fail with "Local model unavailable" + offer deterministic fallback. Block non-loopback hosts. Apple Foundation Models pinned to on-device only.
7. **Performance**: Transcribe command with Parakeet, pause/unload STT, load MLX, run transform, unload on idle. Cap selection at 4000 tokens. Target UX: `Listening` → `Transcribing locally` → `Thinking locally` → `Preview`.
8. **Privacy**: No selected text, command transcript, or result in telemetry/crash logs (redact). No history by default (opt-in with per-app exclusion). Secure field = refuse. No window titles in history.

---

## Phased Delivery

- **Phase 0 — Spike (1 sitting).** Hard-wire dedicated hotkey → capture → record → transcribe → transform → paste, behind feature flag `AppFeatures.commandModeEnabled`, no settings UI. Validate end-to-end in TextEdit, Notes, Slack, Mail, Safari textarea, VS Code/Cursor.
- **Phase 1 — MVP behind flag.** `CommandModeCoordinator`, dedicated trigger + Settings accessor + conflict validation, `.command` overlay wired (captured selection + live instruction transcript + progress), `transform_history` write with voice tag, content-free telemetry, structural failure buckets and overlay copy. Default off.
- **Phase 2 — Productize.** Settings surface (enable + rebind), onboarding/discoverability copy, telemetry allowlist cross-repo change, docs (spec F-section + ADR-026), staged flag flip to Beta.
- **Later.** Chained commands, saved custom commands, per-app defaults, typed-command fallback, optional dictation fallback on empty selection, optional inline diff/preview.

---

## CLI / Agent-Native Parity

Parity already exists: `macparakeet-cli llm transform --prompt "<instruction>" -` runs a free-text instruction over stdin text through the same `LLMService` path. The GUI Command Mode is the voice front-end onto that proven Core primitive.

---

## Testing Strategy

- **Core (deterministic, no GUI):** Extend `TransformExecutor` test pattern with spoken-instruction case — fake capture backend, fake transcription returning instruction string, `MockTransformLLMService`, fake replacement backend. Assert: instruction passed as `prompt`; empty selection short-circuits; empty instruction handled; structural failure buckets map correctly.
- **Deterministic transforms:** Unit tests for each of the 8 Tier 1 transforms.
- **LLM transform validation:** Test JSON parsing, validation (echo detection, "Sure here is", length checks), retry logic.
- **Coordinator:** Capture → record → transcribe → run → replace ordering; cancel mid-record (Escape) aborts cleanly; re-trigger uses cancel-then-restart serialization.
- **Hotkey:** Dedicated trigger registers, validates conflicts against dictation/meeting/Transform bindings, Escape-cancels.
- **Focus/selection:** Non-activating panel keeps host frontmost; selection survives panel appearance.
- **Local-only routing:** Test `RoutingLLMClient` with `forceLocalOnly=true` routes only to `.inProcessLocal`; fails if unavailable; blocks non-loopback Ollama.
- Run `swift test` before declaring complete (project rule).

---

## Telemetry

New content-free events mirroring Transforms: `command_mode_executed` (provider, model, latency bucket, capture path, replacement path, transform tier), `command_mode_failed` (structural error type), and operation rollup. **Reminder:** any new `TelemetryEventName` is a two-repo change — the website `ALLOWED_EVENTS` allowlist must add the same names or the Worker drops the whole batch. Fold into Phase 2 allowlist change.

---

## Open Questions

1. **Hotkey default.** `Fn+Option` (modifier chord) or double-tap Fn? Must survive conflict matrix.
2. **Provider posture for v1.** TRD says force local MLX only. Confirm.
3. **Empty-selection behavior.** Confirm "Nothing selected" + "Use current paragraph" for v1.
4. **Naming.** "Command Mode" (TRD) vs "Spoken Transforms" (previous plan). TRD uses "Command Mode" — use that.
5. **Model default.** TRD specifies Qwen3-4B-Instruct-2507 in MLX, 2.53 GB DDWQ quant. Confirm.

---

## Risks

- **Quality of free-form instructions.** Dictated instruction messier than hand-tuned prompt; small/local models may follow poorly. Mitigation: same provider choice as Transforms; surface clear failure; "save as Transform" later.
- **Selection capture flakiness in some apps.** Mitigation: reuse AX-first + clipboard-fallback service and its app reliability matrix; fail structurally.
- **Mode confusion.** Mitigation: distinct hotkey + visually distinct overlay (`.command` shows captured selection), never language inference.
- **Scope creep toward "agent mode."** Mitigation: hard boundary = text-in/text-out on selection; anything else stays parked.
- **RAM pressure on 16GB Macs.** Mitigation: sequence STT and LLM, unload Parakeet before loading MLX, quantized KV, model unload on idle.

---

## Current Status / Dev Testing Notes (2026-11-10)

### What is implemented (local, uncommitted in worktree unless noted)

- **Feature gate & hotkey:** `AppFeatures.commandModeEnabled = false` by default; debug enable via `--enable-command-mode` (`AppFeatures.isCommandModeAvailable()`). Default Command Mode hotkey: `Control+Option` (`HotkeyTrigger.defaultCommandMode`, persisted via `HotkeyTrigger.commandModeDefaultsKey`). Dictation defaults remain Fn (`defaultDictation` / `defaultPushToTalk`).
- **Core (MacParakeetCore):** `DeterministicTextTransforms` (8 Tier 1 transforms + phrase matching), `CommandModeTransformService` (intent classification replace/panel/unsupported, app-aware prompts with data-only `<selected_text>` wrapping + delimiter neutralization, JSON output parsing/validation with echo/preamble/overlong checks, one-retry flow), `CommandModeTransformExecutor` (deterministic-first, fail-closed local-only `.inProcessLocal`, constrained options/temp 0.1, bounded output, cancellation-safe, non-leaking errors). `RoutingLLMClient` helpers `inProcessLocalClient` / `makeCommandModeLocalContext()`. `CommandModePreviewBehavior` + prefs in `AppRuntimePreferences`. `SelectionCaptureService.restoreClipboardCaptureIfCurrent(...)` made public.
- **App/UI wiring:** `CommandModeCoordinator` (app layer) — capture selection/context before recording, secure-field/terminal/excluded-app handling, toggle hotkey to record/stop, local transcription via speech engine, transform/apply/preview flow, internal-only command transcript, clipboard restore on abandon, 10s undo window to restore original. Overlay hooks for command session/kind and command-specific content; shows "Command" label, "Local only, no network" badge, and dynamic stages (`Transcribing locally` / `Thinking locally` / preview/applying messages). Settings row for **Command Mode** hotkey with conflict validation; `SettingsViewModel.commandModeHotkeyTrigger` + notification. `AppDelegate` creates/wires coordinator and `GlobalShortcutManager`, refresh/suspend/stop handling (behind feature flag). Command hotkey added to reserved/conflict lists and `HotkeyConflictPolicy` (new `commandMode` surface/snapshot support and call-site updates).
- **Key files:** `Sources/MacParakeet/App/CommandModeCoordinator.swift`, `Sources/MacParakeetCore/Services/Transforms/{DeterministicTextTransforms,CommandModeTransformService,CommandModeTransformExecutor}.swift`, `Sources/MacParakeetCore/Services/LLM/RoutingLLMClient.swift`, `Sources/MacParakeetCore/Hotkey/HotkeyConflictPolicy.swift`, `Sources/MacParakeet/AppDelegate.swift`, `Sources/MacParakeet/Views/Settings/SettingsView.swift`, `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`, `Sources/MacParakeetViewModels/SettingsViewModel.swift`, `Sources/MacParakeetCore/AppFeatures.swift`, `Sources/MacParakeetCore/STT/HotkeyTrigger.swift`, `Sources/MacParakeetCore/AppRuntimePreferences.swift`, `Tests/MacParakeetTests/Transforms/CommandModeTransformTests.swift`.

### What worked (verified)

- `swift build --target MacParakeetCore`: passed (earlier).
- `swift build`: passed for Command Mode changes before pull; passed again after fixing a compile error introduced by the UX-polish pull.
- `swift test --filter CommandModeTransformTests`: **18/18 passed** before pull (deterministic transforms, intent classification, output validation/parsing/safety, data-only prompt wrapping + delimiter neutralization).
- `agent-desktop@1.2.0` installed (`/opt/homebrew/bin/agent-desktop`); dev app launched with `scripts/dev/run_app.sh --enable-command-mode`.

### What did not work / issues found

- **agent-desktop UI automation blocked in this environment:** `agent-desktop status` reports `accessibility.state: "denied"` for the environment running commands here, so `snapshot/click/list-windows --app` fail with `PERM_DENIED` (screen recording granted). `agent-desktop permissions --guide` and System Settings Accessibility were opened, but permission must be granted to the specific host/process running this session and may require restart; automated UI pass could not be completed.
- **Pulled latest `origin/main` (UX polish, `f1f5983b`) caused build/test issues locally:**
  - `swift build` initially failed: `Sources/MacParakeet/Views/History/DictationHistoryView.swift` had invalid `.frame(minWidth:maxWidth:height:)` — fixed locally by splitting into two `.frame(...)` calls.
  - `Tests/MacParakeetTests/Views/DictationOverlayChromeTests.swift` referenced removed `DictationOverlayChrome` — deleted locally as stale.
  - `swift test --filter CommandModeTransformTests` could not complete after pull because the test target still has other unrelated compile failures from pulled changes (investigation/fixes needed).
- **Dev app global hotkeys not working (user-reported, unresolved):** User tested **MacParakeet Dev** with Accessibility and Input Monitoring toggled on, launched via `scripts/dev/run_app.sh --enable-command-mode`. **Fn** and **Control+Option** did not trigger. Notes: macOS "Press 🌐 key to" was set to Do Nothing; `ioreg` showed no obvious SecureInput flag; dev log at printed path was empty in this check. At one point both stable `/Applications/MacParakeet.app` and dev build were running simultaneously (can interfere with global shortcuts) — stable should be fully quit; issue still reported after attempts. Possible causes to investigate next: TCC not actually effective for ad-hoc-signed/rebuilt dev bundle (remove/re-add running app in Accessibility & Input Monitoring, relaunch), macOS **Keyboard → Dictation** shortcut claiming Fn, correct shortcut/binding/conflict state in dev Settings, hotkey registration/startup or suspension in `AppDelegate`/`GlobalShortcutManager` for dev build, and whether a properly signed dev identity improves TCC stickiness.

### Local working tree state (after testing)

- Branch `main` at `f1f5983b` (up to date with `origin/main` at time of notes).
- Uncommitted local changes: modified `Sources/MacParakeet/Views/History/DictationHistoryView.swift` (build fix for pulled UX change) and deleted `Tests/MacParakeetTests/Views/DictationOverlayChromeTests.swift` (stale test). Command Mode implementation changes described above may also be uncommitted depending on what was staged/committed previously — verify with `git status` before resuming.

### How to run/install (dev)

- Build and launch dev app: `scripts/dev/run_app.sh`
- Build and launch with Command Mode enabled (required each launch for now): `scripts/dev/run_app.sh --enable-command-mode`
- Default Command Mode shortcut: **Control+Option** (configurable in Settings → Dictation/Shortcuts). Dictation defaults to **Fn**.

### Continue from here (next steps)

1. **Unblock dev hotkeys:** reproduce with only MacParakeet Dev running; verify Accessibility + Input Monitoring granted to the exact running dev bundle (remove/re-add), check macOS Keyboard → Dictation shortcut, confirm bindings/conflicts in Settings, and inspect runtime logs/hotkey registration (`GlobalShortcutManager`/`AppDelegate`) for failures. Consider testing with a stable signing identity if available.
2. **Stabilize tree after UX-polish pull:** fix remaining test-target compile errors so `swift test --filter CommandModeTransformTests` (and broader targeted tests) run; decide whether to keep/rework the local `DictationHistoryView` and deleted stale test changes.
3. **Complete remaining TRD/MVP items:** Settings UI for preview behavior exposure/persistence end-to-end, full non-activating Before/After diff preview with Accept/Retry/Cancel, full preview/undo semantics (10s toast + `Cmd+Z`/Restore original where appropriate), intent-based panel actions for summarise/extract (Insert below/Copy, do not destroy), explicit "Use current paragraph" choice, secure-field detection/refusal hardening, per-app history exclusion UI/behavior and no window titles in history, telemetry/crash-log redaction (content-free events, allowlist coordination), STT→LLM sequencing/unload-on-idle and selection/token caps, loopback-only/Apple-FM-on-device enforcement details, and network kill-switch verification.
4. **Verification:** run focused tests for touched areas and, as a final gate for substantial code changes, a full `swift test` once green. Use `scripts/dev/run_app.sh --enable-command-mode` for manual Command Mode QA (selection rewrite, deterministic vs LLM, preview/undo, local-only/fail-closed behavior).
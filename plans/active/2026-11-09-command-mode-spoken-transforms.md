# Command Mode — Voice-Driven Transforms on Selected Text

**Status:** PROPOSED — not started
**Date:** 2026-11-09
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
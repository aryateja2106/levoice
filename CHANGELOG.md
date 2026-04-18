# Changelog

All notable changes to LeVoice will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version policy:

- **Major** (`X.0.0`) — breaking changes to settings schema, hotkey defaults that
  invalidate user muscle memory, model format incompatibilities, or removal of
  documented features.
- **Minor** (`0.X.0`) — new user-facing features (a new settings tab, a new model,
  a new context-aware behavior, a new paste mode).
- **Patch** (`0.0.X`) — bug fixes, dependency bumps, copy edits, performance
  improvements that do not change behavior.

Each release entry must include the build number in parentheses next to the
version, the release date, and a short summary line. Unreleased work
accumulates under the `[Unreleased]` heading at the top.

---

## [Unreleased]

### Planned

- Per-app cleanup model routing with NL2Shell for terminals (see
  `levoice-spec-context-routing.md`).
- Clipboard history + Trimmy-style paste flattening (see
  `levoice-spec-clipboard.md`).
- Menu-bar microphone input switcher.
- Default hotkey rebind to `Fn` (push-to-talk) and `Fn+Space` (toggle).
- Replace inherited Ghost Pepper chili artwork with the LeSearch waveform mark.

---

## [0.0.1] (build 1) — 2026-04-17

First tagged LeVoice build. Internally distributable; **not yet signed or
notarized** (Apple Developer enrollment pending).

### Added

- New `LICENSE` file with dual MIT attribution: original Ghost Pepper copyright
  (Matthew Hartman, 2024–2026) plus LeVoice fork copyright (Arya Teja
  Rudraraju / LeSearch AI, 2026). Third-party dependency table covering
  WhisperKit, FluidAudio (Apache-2.0), LLM.swift, Sparkle.
- Commercial-distribution prep doc (`levoice-commercial-prep.md`) covering
  Apple Developer enrollment, notarization, Sparkle setup, payment options.
- Architecture map (`levoice-architecture.md`) — subsystem-by-subsystem mental
  model of the codebase.
- Two product specs:
  - `levoice-spec-context-routing.md` — per-app cleanup model routing,
    NL2Shell terminal integration.
  - `levoice-spec-clipboard.md` — clipboard history + paste-trim, voice-driven.
- Build/release scaffolding: `CHANGELOG.md` (this file), `RELEASE.md`
  (the runbook for cutting a build).

### Changed

- Project renamed Ghost Pepper → LeVoice across ~40 source/config files:
  `pepperbox/GhostPepper/` → `pepperbox/LeVoice/`,
  `GhostPepperApp.swift` → `LeVoiceApp.swift`,
  `GhostPepper.entitlements` → `LeVoice.entitlements`,
  `GhostPepperTests/` → `LeVoiceTests/`. Bundle identifier updated to
  `ai.lesearch.levoice`. XcodeGen `project.yml` is now the source of truth;
  `LeVoice.xcodeproj` regenerates from it.
- `build-dmg.sh` now reads signing identity + team ID from environment
  variables (`LEVOICE_SIGNING_IDENTITY`, `LEVOICE_TEAM_ID`) instead of the
  hardcoded Ghost Pepper credentials. Stock script still has Matt's identity
  as TODO placeholders that fail loudly if not overridden.
- `appcast.xml` replaced with a placeholder; `SUFeedURL` removed from
  `Info.plist` so the app does not auto-update from the upstream Ghost Pepper
  release feed. Auto-update will be re-enabled in a future release once the
  LeSearch AI release host is set up.
- Onboarding window: removed the "Tell Matt you're trying out Ghost Pepper"
  tweet button (was Matt's marketing surface, not ours).
- README rewritten for LeVoice positioning + LeSearch AI branding. Stale
  GitHub URLs swept to the `lesearch-ai/levoice` placeholder org.

### Fixed

- Restored MIT attribution line in `Info.plist` (`NSHumanReadableCopyright`)
  after a sed sweep accidentally clobbered "Based on Ghost Pepper by Matthew
  Hartman" to "Based on LeVoice by Matthew Hartman". Required by MIT.

### Known issues

- Default hotkey is `right-Cmd + right-Option` (inherited from Ghost Pepper)
  rather than `Fn` (Arya's preference). Rebind in Settings → Recording or
  wait for the planned default change.
- Status bar icon and app icon are still the inherited Ghost Pepper chili
  artwork. New LeSearch waveform mark is in `levoice-logo-masters/` but not
  yet exported into the asset catalog.
- Sparkle auto-update is disabled (no `SUFeedURL`).
- App is unsigned. On a fresh Mac, Gatekeeper will refuse to launch it
  without a manual `xattr -cr /Applications/LeVoice.app` or
  System Settings → Privacy & Security → "Open Anyway".
- Build emits ~11 Swift 6 actor-isolation warnings (non-blocking).

### Security notes

- No telemetry, no analytics, no crash reporting SDKs. Microphone audio,
  transcripts, and cleanup output never leave the device.
- Microphone and Accessibility permissions are required at runtime; both are
  prompted via standard macOS TCC dialogs on first use.

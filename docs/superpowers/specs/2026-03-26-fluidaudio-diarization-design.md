# FluidAudio Diarization Design

## Goal

Add a first-pass `Ignore other speakers` feature that works only on the `FluidAudio` speech path, uses diarization to follow the first substantial speaker in a recording, and improves stop-and-paste dictation without exposing live transcript UI.

## Why

Ghost Pepper is still a stop-and-paste app, but the longer-term platform direction is broader:

- multi-speaker continuous conversation transcripts
- online analysis over a live session
- richer speaker-aware transcript tooling

The first product need is narrower:

- reduce contamination from other people speaking in the room
- keep the final transcript focused on Jesse’s voice in the common push-to-talk case

This feature should therefore do two things at once:

- ship a practical stop-and-paste improvement now
- establish a session-oriented core that can grow into future speaker-aware streaming products later

## Scope

In scope:

- add a Recording-pane toggle: `Ignore other speakers`
- show that toggle at all times
- enable it only when the selected speech model uses `FluidAudio`
- keep it disabled, with no note, for `WhisperKit` models
- run diarization only on the `FluidAudio` path
- identify the first substantial speaker in the recording and keep that speaker’s later spans
- transcribe only the kept spans
- run cleanup as normal after the final speaker-filtered transcript is produced
- preserve enough session structure internally to support future streaming-first work
- expose diarization visualization only in the Transcription Lab

Out of scope for V1:

- diarization for `WhisperKit`
- live transcript UI
- speaker enrollment or saved speaker profiles
- overlap-aware source separation
- multi-speaker final transcripts
- speaker labels in pasted output

## Product Behavior

### Recording Settings

Add one new setting in the `Recording` pane:

- `Ignore other speakers`

Behavior:

- if the selected speech model is `FluidAudio`, the user can enable or disable it
- if the selected speech model is `WhisperKit`, the toggle remains visible but disabled
- there is no explanatory note under the disabled toggle

### Live Dictation Behavior

When `Ignore other speakers` is off:

- Ghost Pepper behaves exactly as it does today

When `Ignore other speakers` is on and the selected speech model uses `FluidAudio`:

1. record audio normally
2. process diarization incrementally while recording is in progress
3. track the first substantial speaker for that session
4. on stop, finalize that speaker’s kept spans
5. transcribe only the kept spans with the selected `FluidAudio` speech model
6. run cleanup normally on the finalized transcript
7. paste the final cleaned result

The user still only sees one final transcript after stop.

There is no live partial transcript UI in this feature.

## First-Speaker Heuristic

V1 intentionally uses a simple rule:

- the first substantial speaker detected in the recording becomes the target speaker

“Substantial” means:

- not a tiny fragment or incidental noise
- enough voiced speech to be worth following for the rest of the clip

The exact threshold can be tuned during implementation, but it should be in the range of roughly half a second of voiced speech rather than a single tiny burst.

Known failure case Jesse explicitly accepts:

- if somebody else speaks first, Ghost Pepper may follow the wrong speaker for that recording

This is acceptable for V1.

## Why `Sortformer`

Use `FluidAudio`’s `Sortformer` diarization path for V1.

Reasons:

- it is a better fit for streaming-capable processing than a purely batch-only design
- its likely failure mode is missing quieter speech rather than aggressively misassigning speakers
- that is a better tradeoff for `Ignore other speakers`, where false inclusions are usually worse than a few missed words
- it aligns better with the future platform direction than building around a one-off offline-only diarizer

This design does not require exposing streaming transcript UI, but it does benefit from a streaming-capable diarization engine internally.

## Architecture

### Design Principle

Build streaming-capable internals now, but keep the first user-visible product behavior simple:

- internal timeline may revise while the recording is in progress
- the user only sees the final result after stop

This avoids painting the app into an offline-only corner while keeping V1 behavior predictable.

### Core Components

#### RecordingSessionCoordinator

Owns one active dictation session.

Responsibilities:

- receive audio chunks from the recorder
- fan those chunks out to downstream consumers
- own session lifecycle
- finalize all session outputs when recording stops

This is the central seam that future continuous-transcript and online-analysis features can build on.

#### AudioChunkTimeline

Represents the audio captured during a session as ordered chunks with timing metadata.

Responsibilities:

- preserve chunk ordering and timing
- provide the source material for diarization and ASR
- support extracting merged kept spans after diarization finalization

V1 does not need a complicated storage layer here. An in-memory timeline backed by the existing final audio buffer is sufficient as long as the interfaces are chunk-oriented.

#### SpeakerAttributionEngine

Wraps `FluidAudio` diarization for the current recording session.

Responsibilities:

- ingest audio chunks while recording
- produce provisional speaker spans
- select the first substantial speaker
- decide which later spans belong to that same speaker
- finalize the kept spans at stop

The engine should expose “kept” vs “discarded” spans explicitly so the lab can visualize them later without reverse-engineering the decision.

#### TargetSpeakerTranscriptBuilder

Builds the transcription input from the kept spans.

Responsibilities:

- merge nearby kept spans with a small gap tolerance
- extract the corresponding audio
- hand only that audio to the selected `FluidAudio` ASR backend

This component keeps the diarization policy separate from the ASR backend logic.

#### CleanupFinalizer

Runs existing cleanup unchanged after the speaker-filtered transcript is finalized.

Responsibilities:

- accept the final raw transcript
- reuse the existing cleanup pipeline
- remain agnostic to whether the transcript came from full audio or filtered speaker spans

This keeps cleanup from becoming entangled with diarization internals.

## Data Flow

### Recording Start

1. `AudioRecorder` starts capturing as it does today
2. `RecordingSessionCoordinator` opens a new session
3. audio chunks are appended to `AudioChunkTimeline`
4. if the selected speech model is `FluidAudio` and `Ignore other speakers` is enabled:
   - feed chunks into `SpeakerAttributionEngine`
5. if the setting is off, or the model is `WhisperKit`, skip speaker attribution entirely

### Recording Stop

If diarization is inactive:

- use the existing transcription path

If diarization is active:

1. finalize speaker spans
2. select the target speaker using the first-substantial-speaker rule
3. merge the kept spans
4. build filtered audio from those spans
5. transcribe the filtered audio with the active `FluidAudio` speech model
6. run cleanup normally
7. paste normally

## Fallback Rules

The feature should fail soft.

If any of the following happens:

- diarization initialization fails
- diarization returns no usable speaker spans
- the kept spans are too short to trust
- filtered audio extraction fails

then Ghost Pepper should fall back to the normal full-audio transcript path for that recording.

This avoids losing dictation completely when the speaker filter is uncertain or broken.

## Lab Behavior

The Transcription Lab is the only place where diarization is visualized.

For `FluidAudio` recordings with `Ignore other speakers` enabled, show:

- diarized speaker spans across the clip
- which spans were kept
- which spans were discarded
- the filtered transcript result
- the normal transcript result when useful for comparison

This is a debugging and trust-building surface, not a production interaction model.

The normal live dictation UI should not gain new speaker visuals.

## Current Codebase Reality

This design follows the existing seams in the current branch:

- `SpeechModelCatalog` already distinguishes `WhisperKit` vs `FluidAudio`
- `ModelManager` already branches loading and transcription by backend
- `SettingsWindow` already owns the `Recording` pane and Transcription Lab UI
- `AppState` already coordinates recording, transcription, cleanup, and performance logging

That means V1 can be added by extending the current app structure instead of rewriting the speech stack.

## File Responsibilities

### Existing files likely to change

- `GhostPepper/AppState.swift`
  - own the new setting and route live recordings through diarization when applicable
- `GhostPepper/Transcription/ModelManager.swift`
  - expose enough backend capability to support `FluidAudio` diarization sessions
- `GhostPepper/Transcription/SpeechModelCatalog.swift`
  - expose whether a speech model supports speaker filtering
- `GhostPepper/UI/SettingsWindow.swift`
  - add the visible-but-disabled `Ignore other speakers` toggle in Recording
  - add diarization visualization in the lab
- `GhostPepper/Audio/AudioRecorder.swift`
  - expose audio chunk data cleanly if the current API is too buffer-oriented

### New files likely to be added

- `GhostPepper/Transcription/RecordingSessionCoordinator.swift`
- `GhostPepper/Transcription/AudioChunkTimeline.swift`
- `GhostPepper/Transcription/SpeakerAttributionEngine.swift`
- `GhostPepper/Transcription/TargetSpeakerTranscriptBuilder.swift`

These names describe domain responsibilities, not implementation history.

## Error Handling

The feature should not create a new user-facing error mode for ordinary dictation.

User-facing rule:

- if speaker filtering cannot be completed safely, return the normal full-audio transcript

Debug visibility:

- log whether diarization was active
- log whether it selected a target speaker
- log whether it fell back to the full-audio path
- log kept-span coverage for the session

This gives enough information for tuning without scaring the user with new failures.

## Performance

Without overlap, diarization would add noticeable post-stop latency.

V1 should therefore overlap diarization work with recording:

- feed diarization incrementally during the recording
- keep most diarization cost off the post-stop critical path

At stop, the app should only need to:

- finalize spans
- extract kept audio
- run ASR
- run cleanup

This is a major reason to use a streaming-capable diarization core even though the user never sees partial text.

## Testing

### Unit tests

- first-substantial-speaker selection
- kept/discarded span decisions
- span merging and gap tolerance
- fallback to full-audio transcription when diarization yields no safe result
- `Ignore other speakers` is disabled for `WhisperKit` models and enabled for `FluidAudio`

### Integration tests

- `FluidAudio` dictation with speaker filtering enabled routes through diarization and filtered transcription
- `WhisperKit` dictation ignores the setting and uses the existing path
- cleanup still runs on the final transcript exactly once
- transcription lab can render kept vs discarded spans for archived runs that recorded diarization metadata

### Performance verification

- compare stop-to-paste latency with and without speaker filtering on representative clips
- verify that overlapping diarization work during recording keeps post-stop overhead acceptable

## Risks

### Wrong first speaker

If someone else speaks first, V1 will follow the wrong person.

This is accepted for the first version.

### Overlapping speech

Diarization is not source separation.

If multiple people talk over each other, V1 may still include contamination or miss words. This is a product limitation, not an implementation bug.

### Backend split

`WhisperKit` remains in the app without diarization support.

This keeps product risk down now, but the speech stack remains more complex than a future FluidAudio-only architecture.

## Recommended Implementation Order

1. add the new setting and backend-capability plumbing
2. add session and chunk timeline primitives
3. integrate `FluidAudio` diarization behind the new setting
4. build filtered-audio transcription
5. add lab visualization
6. add performance logging and fallback diagnostics

## Success Criteria

This feature is successful when:

- Ghost Pepper can ignore side speakers in common push-to-talk recordings on `FluidAudio`
- the setting is visible in Recording and disabled cleanly for `WhisperKit`
- ordinary dictation still returns a transcript even when diarization cannot produce a safe result
- the lab makes diarization decisions inspectable without adding new complexity to the live product
- the internal session architecture is a credible base for future speaker-aware streaming features

# Manual Acceptance Checklist

Plan §17.4's thirteen scenarios, for a human tester on a real Mac with a real microphone and a
real LM Studio instance. Nothing here is automatable — that is exactly why it exists separately
from `./scripts/test.sh`, which covers the logic underneath each scenario with fakes and stubs.

This checklist has never been run: every machine this project has been built on so far has no
attached display and no real microphone (see `IMPLEMENTATION_STATUS.md`, "Known limitations").
Each item below states what to do, what "pass" looks like, and — so a tester knows what is
genuinely being exercised for the first time versus reconfirmed — which automated tests already
cover the logic involved.

For every scenario: confirm no crash, no data loss (captured audio survives even if a later
stage fails), and an error, when one occurs, includes a clear message and at least one recovery
action (plan §19) rather than an opaque failure.

## Recording quality

- [ ] **One speaker in a quiet room.** Record ~2 minutes of continuous speech. Live transcript
      should track within a few seconds; final transcript should be substantially accurate.
      *Logic coverage:* `StreamingMerge`/`WhisperKitTranscriber` unit tests exercise the
      stable/unstable merge algorithm with synthetic segments; no automated test transcribes real
      speech.
- [ ] **Two speakers in a quiet room.** Alternate speaking; each turn should get a distinct,
      consistent speaker label, live and final. *Logic coverage:* `FluidAudioDiarizerIntegrationTests`
      (opt-in, `MAIKU_INTEGRATION_TESTS=1`) already runs a real two-speaker fixture through actual
      streaming and file-based diarization on this machine — this scenario reconfirms that result
      face-to-face rather than through a checked-in fixture.
- [ ] **Four speakers with interruptions.** Cross-talk and quick turn changes. Speaker smoothing
      should not fragment one utterance across multiple labels. *Logic coverage:* smoothing is
      unit-tested against synthetic turns only; no automated test uses a real 4-speaker recording.
- [ ] **Background fan noise.** Record with an actual fan or HVAC running. Transcript should stay
      usable; VAD should not treat steady noise as continuous speech. *Logic coverage:* none — no
      automated test includes non-speech background noise.
- [ ] **Long silence.** Leave several minutes of dead air mid-recording. Should not fragment into
      excessive chunks or stall live transcription. *Logic coverage:* `TranscriptChunkerTests`
      covers silence-gap-preferring chunk boundaries against synthetic segment timing, not a real
      silent recording.

## Duration and resources

- [ ] **One-hour recording.** Confirm memory stays bounded (plan §18: never retain a whole
      recording as raw PCM) and the live transcript keeps pace throughout, not just at the start.
      *Logic coverage:* `AudioCaptureService`'s rolling buffers and `WhisperKitTranscriber`'s window
      trimming are unit-tested for the trimming arithmetic, never run for a real hour.
- [ ] **Microphone disconnected during recording.** Unplug an external mic (or disable the input)
      mid-recording. Should surface `MaikuError.microphoneDisconnected`, keep captured audio, and
      offer Refresh Devices / Retry. *Logic coverage:* the error case and its recovery actions are
      defined and unit-tested (`MaikuError`), but no automated test simulates a real device removal.
- [ ] **Disk space becomes low.** Fill the volume during a recording. Should warn before failure
      and offer Choose Storage Location / Delete Old Recordings / Stop Safely.
      *Logic coverage:* well covered — `AudioCaptureService`'s free-space gate and its threshold
      override both have direct unit tests ("Capture preflight" suite) against the real volume.

## Interruption and recovery

- [ ] **App terminated during recording.** Force-quit mid-recording, relaunch. The recovery screen
      should offer Recover and Process / Keep Audio / Delete, and the audio file should be intact.
      *Logic coverage:* well covered — `RecordingCoordinatorTests`/`RecoveryServiceTests` reproduce
      this exact shape (a non-terminal-status row with a real audio file) with fakes; this scenario
      confirms the real `AudioCaptureService`/App lifecycle path matches.
- [ ] **App terminated during final processing.** Force-quit between stop and complete (e.g. during
      transcription or organizing). Relaunch should detect and offer to resume from the right stage.
      *Logic coverage:* same recovery mechanism as above, same test coverage.

## LM Studio failure modes

- [ ] **LM Studio stopped during organization.** Quit LM Studio after a recording finishes
      transcribing. Should report `lmStudioUnreachable` with Retry / Open Settings / Continue
      Without Notes, and the transcript must remain intact and complete regardless.
      *Logic coverage:* well covered — `LMStudioTests` stubs this exact HTTP failure.
- [ ] **LM Studio model returns malformed JSON.** Hardest to trigger deliberately; if a real model
      ever produces invalid structured output, confirm one retry happens automatically and, failing
      that, the error names it as invalid output with Retry Organization / View Diagnostics.
      *Logic coverage:* well covered — `LMStudioTests`/`OutputValidatorTests` exercise the
      retry-once-then-report path and the hallucination/invalid-reference checks extensively against
      stubbed responses.

## Offline

- [ ] **Offline launch with models already installed.** Disable networking entirely (or use a
      firewall rule), with Whisper/diarization models already downloaded and LM Studio already
      running locally. Recording, transcription, diarization, and organization should all work with
      zero network access — `Docs/PRIVACY.md` states this as a tested requirement, not an aspiration,
      and this scenario is what actually proves it. *Logic coverage:* none automated — this can only
      be confirmed by hand, on a real network-disabled machine.

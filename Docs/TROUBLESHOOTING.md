# Troubleshooting

## Microphone

**"maiku does not have permission to use the microphone."**
System Settings → Privacy & Security → Microphone, enable maiku, then restart the app. If maiku
is not listed, it has not asked yet — start a recording once to trigger the prompt.

If you rebuilt maiku from source and the prompt stopped appearing, macOS is tracking the old
code signature. `tccutil reset Microphone com.maiku.Maiku` clears it, and the next launch asks
again.

**"No microphone is connected."**
Check System Settings → Sound → Input. maiku uses the system default input device. Press
**Refresh Devices** after plugging one in.

**The level meter never moves.**
The engine is running but receiving silence. Almost always the wrong input device is selected
system-wide, or the input volume is at zero in System Settings → Sound → Input. Bluetooth
headsets sometimes register as the default output while leaving the built-in mic as input.

**The microphone disconnected mid-recording.**
maiku stops, keeps everything captured so far, and offers to process it. You have not lost the
audio. Reconnect the device and start a new recording for the rest.

## Speech models

**"The speech model … is not installed."**
Settings → Transcription → Download. Downloads need a network connection; after that maiku
works offline.

**"The speech model … failed to load."**
Usually an interrupted download leaving a partial file. Delete the model in Settings and
download it again. If it recurs, try a smaller model — some machines run out of memory
compiling the largest Core ML variants.

**The first transcription after downloading is very slow.**
Core ML compiles the model for your chip on first use. This happens once per model.

**The transcript is poor.**
In rough order of impact: use a better microphone, reduce background noise, pick a larger model,
and avoid people talking over each other. Whisper is also weak on proper nouns and jargon — in
our own testing it rendered "Maiku" as "Maker". Fix these by editing the transcript; your edits
survive reprocessing.

## Speakers

**Everyone is labelled the same speaker.**
Diarization struggles when voices are acoustically similar, the recording is quiet, or everyone
shares one distant microphone. A closer microphone helps more than any setting.

**Speaker boundaries are off by a second or two.**
Known limitation of the current diarization pass. Correct them by hand; renaming a speaker
applies everywhere at once.

**Live speaker labels differ from the final ones.**
Expected. Live labels are provisional and marked as such. The pass that runs after you stop is
canonical, sees the whole recording, and replaces them.

## LM Studio

**"maiku could not reach LM Studio."**
Confirm LM Studio is running and its server is started — the Developer tab, or `lms server
start`. Check the port matches Settings → LM Studio (default `1234`). Verify independently:

```bash
curl http://127.0.0.1:1234/v1/models
```

Note that LM Studio's server does not always start with the app. Any `lms` command will wake it.

**"LM Studio is running but no model is loaded."**
Load a model in LM Studio, then press **Refresh Models** in maiku.

**"LM Studio did not respond within N seconds."**
Large models on long transcripts can exceed the default timeout. Raise it in Settings, or use a
smaller model. Your transcript is safe either way — retry organization without retranscribing.

**"The transcript chunk is too large for the model's context."**
Use **Retry With Smaller Chunks**, or switch to a model with a longer context window.

**"The model returned notes that did not match the expected format."**
maiku already retried once with a repair request. Some models follow JSON schemas poorly —
switching model fixes this more reliably than retrying. **View Diagnostics** shows the raw
response. Your transcript is never discarded because note generation failed.

**maiku warns that the endpoint is not loopback.**
You have pointed it at another machine, so transcript text will travel over the network. That
is allowed but deliberate. Set it back to `http://127.0.0.1:1234` to keep everything local.

## Recordings and recovery

**"An interrupted recording was found."**
maiku found audio from a session that ended unexpectedly. **Recover and Process** transcribes
and organizes it; **Keep Audio** stores the raw file without processing; **Delete** discards it.

**maiku quit during processing.**
Progress is checkpointed per stage. Reopen the recording and retry — completed stages are not
repeated.

**"Low disk space."**
maiku warns before starting and while recording. **Stop Safely** ends the recording and keeps
everything captured so far rather than risking a truncated file.

**A recording will not play.**
Its audio file may be missing or incomplete. Check
`~/Library/Application Support/Maiku/Audio/<recording-id>/`. Transcript and notes remain usable
even when audio is gone.

## Building from source

**`no such module 'Testing'`, or a `lib_TestingInterop.dylib` dlopen failure.**
Run tests through `./scripts/test.sh`, not bare `swift test`. swift-testing ships with the
Command Line Tools, but SwiftPM only wires up its search paths when driven by Xcode; the script
supplies them.

**`xcodebuild: error: tool 'xcodebuild' requires Xcode`.**
Expected, and not a problem. maiku builds with `./scripts/build.sh` using only the Command Line
Tools. Full Xcode is optional.

**The app builds but will not launch, or launches with no microphone prompt.**
Run `./scripts/build.sh` rather than using `.build/debug/Maiku` directly. macOS only grants
microphone permission to a signed `.app` bundle with an `Info.plist`, which is exactly what the
script produces.

## Getting more detail

Settings → Privacy and diagnostics → **Export Diagnostics** writes a local file with recent log
entries and environment details. Transcript content is redacted unless you explicitly include
it. Nothing is uploaded — the file goes where you choose.

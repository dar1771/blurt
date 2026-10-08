# VibeDictate

Native macOS dictation with two modes: speak, stop, and paste text into the
focused field. VibeDictate is based on the MIT-licensed Blurt project and uses
its dependency-free Swift engine, `BlurtEngine`.

## Current status

Development and manual acceptance are in progress. A signed and notarized
VibeDictate release has not yet been verified. Build locally using
[CONTRIBUTING.md](./CONTRIBUTING.md); see [manual acceptance](./VIBEDICTATE_ACCEPTANCE.md)
and [release readiness](./VIBEDICTATE_RELEASE_AUDIT.md).

When an approved release is available, its download will be
[VibeDictate.dmg](https://github.com/dar1771/blurt/releases/latest/download/VibeDictate.dmg).
The image contains `VibeDictate.app`; drag it to `Applications`.

## Dictation modes

- **Fast — right ⌘ by default:** MAI-Transcribe 2 through OpenRouter, with no
  second normalization request.
- **Accurate — right ⌥ by default:** for recordings shorter than 115 seconds,
  MAI followed by OpenRouter normalization. If MAI fails, Universal-2 is the
  fallback. Longer recordings use AssemblyAI Universal-2 with Russian language,
  then normalization.
- Tap to start/stop, or hold for push-to-talk. Settings let you change the keys
  and the OpenRouter models. These modes can return identical text on simple phrases.
- MAI uploads use a smaller AAC/M4A copy by default; the original WAV remains in
  history. Disable «Ускорить отправку аудио» in Settings to upload WAV if compression
  affects recognition. Conversion failure or an unsupported-format response falls
  back to WAV. Normalization requests prefer providers with lower latency.
- The overlay shows microphone level and processing state. Text is pasted using
  ⌘V; the previous clipboard is restored after a successful paste. If the target
  is lost, the transcript remains available for copying.
- History supports repeat insertion and an audio player with pause and seeking.
  Settings list the audio inputs macOS makes available, with a refresh button.
- Updates are downloaded and installed by the user. The app checks at most once
  a day after launch and when requested; it does not replace itself.

## Requirements and setup

- Mac (Intel or Apple Silicon), macOS 15+; macOS 26 is recommended.
- Your AssemblyAI API key for Universal-2 and your OpenRouter API key for MAI
  and normalization. Provider usage can incur charges.
- Microphone and Accessibility permissions for the installed app.

Launch VibeDictate, complete setup, and enter keys in Settings. Focus a text
field, tap the mode key, speak, and tap again to stop. Wait for the result.
The app displays processing errors; a normalization failure preserves the
original transcription. Real manual coverage is documented in the acceptance
file; automated UI tests use offline doubles.

## Data and privacy

API keys are stored in the macOS Keychain. Release and Dev builds use separate
services (`vibedictate` and `vibedictate-dev`) and separate permissions/settings
under `app.vibedictate` and `app.vibedictate.dev`.

Audio is captured while dictating and sent over HTTPS to the provider selected
by the mode and recording length: OpenRouter for MAI, AssemblyAI for Universal-2.
Accurate mode sends the transcript to OpenRouter for normalization. Local app,
window, field and selection metadata are not included in STT requests.

Audio and history are saved locally under
`~/Library/Application Support/VibeDictate/`. Retention removes audio older than
3 days and history older than 30 days when maintenance runs. Developer mode
additionally writes diagnostic dictation/error logs under
`~/Library/Logs/VibeDictate/`. Settings reset clears the AssemblyAI key, settings, permissions
and those diagnostic logs; it retains the OpenRouter key, saved audio and history.
The terminal reset script additionally removes the OpenRouter key for both builds. No telemetry is sent.

Provider handling is governed by [AssemblyAI's privacy policy](https://www.assemblyai.com/legal/privacy-policy)
and [OpenRouter's privacy policy](https://openrouter.ai/privacy).

## Build and contribute

```bash
git clone https://github.com/dar1771/blurt.git
cd blurt
scripts/bootstrap.sh
scripts/dev-build.sh
```

The signed Debug-Local build installs to `/Applications/VibeDictate Dev.app`
(or `~/Applications` fallback). Technical names remain `BlurtEngine`, target and
scheme `Blurt`, executable `Blurt`, and paths under `App/Blurt`.

`scripts/check.sh` is the health gate. Locally it skips UI/leak integration
steps that take over the keyboard; CI on `macos-26` runs them. Missing linters
mean missing coverage. `scripts/check.sh --portable` does not verify Swift builds.

Read [AGENTS.md](./AGENTS.md) before architectural changes,
[CONTRIBUTING.md](./CONTRIBUTING.md) for setup and PRs, and
[RELEASE.md](./RELEASE.md) for certificate configuration and release gates.

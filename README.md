<img src="assets/logo.svg" width="84" alt="twintape logo: two twin tape reels">

# twintape

Minimal meeting recorder for macOS. Two twin tapes, one per side of the conversation: your mic and the system audio, saved as separate mono WAVs so "you" and "them" stay attributable without any diarization model. One global shortcut to start and stop. A border around your screen tells you when it is recording. No window, no account, no backend.

twintape only records. Transcription is composition, not a feature: pipe the tapes into [trx](https://github.com/crafter-station/trx) or any tool you prefer.

Built on [Native SDK](https://native-sdk.dev) as an open source dogfooding project: every capability the SDK is missing becomes an upstream PR.

## Usage

twintape is menu-bar-first: there is no window at all, ever. Everything happens through the menu bar status item.

**Start and stop**: press `cmd+shift+r` anywhere, even while another app has focus (it is a global hotkey, not a local shortcut), or use the "Grabar"/"Detener" row in the menu bar. The status item's title flips to `● MM:SS` while recording.

**The border**: while recording, a thin red line traces the edge of the screen. It never intercepts clicks (it is click-through), so it never gets in the way of what you are doing. Idle, nothing is drawn anywhere on screen - not even an invisible window claiming clicks.

**Menu bar**: click the "twintape" status item for Grabar/Detener, "Abrir grabaciones" (opens the current session folder in Finder), and Salir (quits the app). The title always shows the current state: a plain "twintape" idle, a fault label if the last capture failed, `● MM:SS` while recording.

**Where sessions land**: every recording writes to its own timestamped folder under `~/Library/Application Support/twintape/<YYYY-MM-DD-HHMMSS>/`, with `mic.wav` and `system.wav` inside. "Abrir grabaciones" opens this folder directly.

## Transcribing

twintape does not transcribe. Pipe each track through [trx](https://github.com/crafter-station/trx) separately, once per file:

```bash
trx transcribe ~/Library/Application\ Support/twintape/2026-08-06-213607/mic.wav
trx transcribe ~/Library/Application\ Support/twintape/2026-08-06-213607/system.wav
```

Two transcripts, two speakers, no diarization model needed: the mic track is you, the system track is everyone else. Merge and align them however your workflow prefers.

## Status

Shaped, in progress. See `src/main.zig`'s file doc for the current SDK gaps this build ran into and worked around.

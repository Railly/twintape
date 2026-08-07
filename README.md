# twintape

Minimal meeting recorder for macOS. Two twin tapes, one per side of the conversation: your mic and the system audio, saved as separate mono WAVs so "you" and "them" stay attributable without any diarization model. One global shortcut to start and stop. A pill at the bottom of the screen and a border around it tell you when it is recording. No window, no account, no backend.

twintape only records. Transcription is composition, not a feature: pipe the tapes into [trx](https://github.com/crafter-station/trx) or any tool you prefer.

Built on [Native SDK](https://native-sdk.dev) as an open source dogfooding project: every capability the SDK is missing becomes an upstream PR.

## Usage

**Start and stop**: press `cmd+shift+r` anywhere, even while another app has focus (it is a global hotkey, not a local shortcut). The pill and the status item both flip to the recording state.

**The pill**: a thin gray strip anchored bottom-center of the screen, always on top. It turns red while recording. There is no titled window; the pill is the whole visible surface twintape shows on its own.

**Hover the pill**: it expands into a small panel with the current status, elapsed time, a Grabar/Detener button, and an "Abrir grabaciones" button that opens the session folder in Finder. It collapses back to the pill shortly after the pointer goes quiet in that area (moving away, or just sitting still for a moment).

**The border**: while recording, a thin red line traces the edge of the screen. It never intercepts clicks (it is click-through), so it never gets in the way of what you are doing.

**Menu bar**: the status item mirrors the same Grabar/Detener toggle and shows the elapsed time in its title. Salir quits the app.

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

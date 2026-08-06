# twintape

Minimal meeting recorder for macOS. Two twin tapes, one per side of the conversation: your mic and the system audio, saved as separate mono WAVs so "you" and "them" stay attributable without any diarization model. One global shortcut to start and stop. A border around your screen tells you when it is recording. No window, no account, no backend.

twintape only records. Transcription is composition, not a feature: pipe the tapes into [trx](https://github.com/crafter-station/trx) or any tool you prefer.

Built on [Native SDK](https://native-sdk.dev) as an open source dogfooding project: every capability the SDK is missing becomes an upstream PR.

Status: shaped, V1 in progress.

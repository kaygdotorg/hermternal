# Changelog

All notable changes to Hermternal are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow Semantic Versioning.

## [v0.0.2] — 2026-08-22

This feature release makes the app usable for signed-in sessions: the previous
release could not reliably load chats or messages, while this release adds
working search, credential refresh, and a rebuilt Settings window.

### Added

- Search across indexed conversation history, including result navigation into
a chat and find-in-conversation.
- Gateway settings and account identity in the app's native Settings window.
- Keychain-backed credential storage with the existing file-backed path retained
as a fallback where Keychain access is unavailable.
- Visible-time toast notifications and an honest indexing indicator that reports
real progress instead of showing a permanent spinner.

### Changed

- WebSocket text frames are decoded as complete messages, so replies no longer
wait forever for a newline and chats/messages can load.
- REST history is paged beyond the 500-message server limit, so search indexes
whole transcripts where the gateway exposes their rows.
- Search-field presentation now fades and refracts scrolling content around the
glass field without emptying the underlying transcript.
- Settings is presented as a native AppKit window with a full-height sidebar,
matching the platform's window chrome and materials.
- Authentication refreshes when the gateway rejects an expired bearer token,
not only when the local clock predicts expiry.
- Cache filenames preserve distinct session identifiers, avoiding transcript
loss when identifiers differ only by punctuation.

### Known limitations

- Two sessions contain compaction-preserved rows that remain unindexed pending
the decision tracked in issue #34. Those rows are not claimed as searchable by
this release.

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/

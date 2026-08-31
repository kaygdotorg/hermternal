# Changelog

All notable changes to Hermternal are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow Semantic Versioning.

## [Unreleased]

### Added

- A width toggle in the window's toolbar, and in the View menu, switches the
  transcript between the reading measure and the full window. The choice is
  remembered.

### Changed

- Build and release tooling now refuses stale, incomplete, unsigned, or
  provenance-mismatched app bundles instead of handing them to callers.
- Both speakers share one text measure. A message the user wrote is no longer
  held to 70% of the column the answer below it fills.
- Reload moved out of the toolbar into the View menu, on its standard ⌘R.

## [v0.0.4] — 2026-08-23

This release gives the application a native app icon and tightens sidebar and
deep-link behavior.

### Added

- An appearance-aware native app icon, compiled from an Icon Composer package
  into the bundle's asset catalog, so macOS draws the light or dark artwork
  itself.
- The new-chat state is an icon-only mark with no heading or subtitle, and it
  falls back to a system glyph when the bundle resource is absent.

### Changed

- The sidebar shows one left caret and no native right caret, aligns rows with
  Schedules using a 10pt folder-child offset, and mirrors its top and bottom
  fades at 48pt.
- A folder child chat menu no longer inherits the folder menu, and the focused
  source glyph keeps sufficient contrast.
- A valid cold-launch deep link waits for the app to become ready and the
  session list to complete before it opens.
- The release keeps the existing deterministic performance contracts and
  release verification flow.

### Known limitations

- Attachments, voice input, model controls, and reasoning controls are not
  implemented.
- Automatic updates are not implemented yet.

## [v0.0.3] — 2026-08-23

This feature release improves sidebar organization and makes release execution
more reliable.

### Added

- Organize chats into folders, reorder them by drag, and keep scheduled runs in
their own sidebar section.
- Show the selected gateway identity in a compact gateway pill.
- Open chats and target messages from deep links.

### Changed

- Pin, archive, and rename chats from the sidebar.
- Release scripts can resume safely, verify signed and notarized artifacts, and
publish only the verified artifact.
- SSH signing uses an ephemeral keychain.
- The performance release check gates deterministic cache, search, markdown,
  disk-footprint, and release-binary contracts. Wall time, CPU, and RSS are
  measured report-only values. Parser invocation, projection rebuild, actual
  SQLite row visits, and allocation reuse are not gated because no counter
  seam exists; they are future measurement gaps.

## [v0.0.2] — 2026-08-22

This feature release makes the app usable for signed-in sessions: the previous
release could not reliably load chats or messages, while this release adds
working search, credential refresh, and a rebuilt Settings window.

### Added
- Search across indexed conversation history, including result navigation into
  a chat and find-in-conversation.
- Gateway settings and account identity in the app's native Settings window.
- Production credentials are stored in an owner-only file under
  `Application Support/Hermternal/credentials`. The Keychain adapter exists as
  an injectable capability, but production composition uses the file-backed
  store.
- Visible-time toast notifications and an indexing status that distinguishes
  queued backlog from active work.

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

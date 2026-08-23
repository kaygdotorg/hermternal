# Hermternal

Hermternal is a native macOS client for the Hermes agent gateway. It lets you sign in through a browser, open Hermes chats, and send messages from a SwiftUI and AppKit application.

## Scope

Hermternal is a client for an existing Hermes gateway. It does not run a gateway or provide a general chat service. You must have access to a reachable Hermes gateway.

## Requirements

- macOS 26 or later.
- A reachable Hermes gateway URL.
- A browser that can complete the gateway sign-in flow.

## Install

1. Open the [v0.0.4 release](https://git.kayg.org/kayg/hermternal-apple/releases/tag/v0.0.4).
2. Download `Hermternal-0.0.4.zip`.
3. Extract the archive.
4. Move `Hermternal.app` to the `Applications` folder.
5. Open Hermternal and enter your Hermes gateway URL. Sign-in opens your browser.

The v0.0.4 archive is notarized. macOS Gatekeeper can verify the application before it starts.

## Build from source

Build on macOS 26 or later from the repository root:

```sh
bash Scripts/build-app.sh
```

The script builds a debug application by default and writes the bundle to:

```text
build/Hermternal.app
```

For a release configuration, run:

```sh
CONFIG=release bash Scripts/build-app.sh
```

## Current features in v0.0.4

- [x] Native SwiftUI and AppKit macOS application.
- [x] Browser-based native sign-in with PKCE and a local callback.
- [x] Hermes gateway connection over its WebSocket JSON-RPC interface.
- [x] List existing chats, create a chat, resume a chat, send a message, and interrupt a reply.
- [x] Stream assistant replies and show gateway errors in the application.
- [x] Optional local chat-history cache with background prefetch, cache progress, rebuild, and clear controls.
- [x] Markdown text, inline formatting, fenced code blocks, code copying, and text selection.
- [x] System, Light, and Dark appearance modes.
- [x] Adjustable window frost setting and native Appearance and Cache settings tabs.
- [x] Persistent server selection and stored sign-in credentials for the selected gateway.
- [x] Reduce Transparency produces an opaque, legible system fallback across existing glass and material surfaces.
- [x] Chat and message deep links open a chat and target a message.
- [x] Sidebar folders organize chats, drag reorder changes their order, and scheduled runs have their own section.
- [x] Sidebar row actions pin, archive, and rename chats.
- [x] The sidebar shows the selected gateway identity in a gateway pill.
- [x] The performance contract runner is available for release audits.
- [x] The application bundle carries an appearance-aware native macOS app icon.
- [x] The new-chat state is an icon-only mark, with no placeholder copy.
- [x] The sidebar shows one left caret, aligns rows with Schedules, and mirrors its top and bottom fades.
- [x] A cold-launch deep link waits for the application to become ready and the chat list to finish loading before it opens.

## Planned work

These items are tracked in Forgejo. The issue descriptions are the source of truth for planned behavior.

### Search and navigation

- [x] [Chat and message deep links](https://git.kayg.org/kayg/hermternal-apple/issues/4).
- [ ] [Local chat search with Command-K](https://git.kayg.org/kayg/hermternal-apple/issues/8).
- [ ] [Core Spotlight indexing](https://git.kayg.org/kayg/hermternal-apple/issues/11).
- [ ] [Command-Shift-K action mode](https://git.kayg.org/kayg/hermternal-apple/issues/22).
- [ ] [Command-F find in the current conversation](https://git.kayg.org/kayg/hermternal-apple/issues/23).

### Composer and messages

- [ ] [Voice notes, attachments, and model or reasoning controls](https://git.kayg.org/kayg/hermternal-apple/issues/2).
- [ ] [iMessage-like chat bubbles](https://git.kayg.org/kayg/hermternal-apple/issues/5).
- [ ] [Markdown-first composer and message bubbles](https://git.kayg.org/kayg/hermternal-apple/issues/6).

### Platform and integration

- [ ] [Accent color settings](https://git.kayg.org/kayg/hermternal-apple/issues/3).
- [ ] [Curated Appearance theme gallery](https://git.kayg.org/kayg/hermternal-apple/issues/7).
- [ ] [Native motion pass](https://git.kayg.org/kayg/hermternal-apple/issues/9).
- [ ] [Help settings tab](https://git.kayg.org/kayg/hermternal-apple/issues/10).
- [ ] [App Intents for Siri and Shortcuts](https://git.kayg.org/kayg/hermternal-apple/issues/12).
- [ ] [Accessibility audit and remediation](https://git.kayg.org/kayg/hermternal-apple/issues/13).
- [ ] [NavigationSplitView divider decision record](https://git.kayg.org/kayg/hermternal-apple/issues/27).

### Infrastructure

- [ ] [Password sign-in test gateway and client support](https://git.kayg.org/kayg/hermternal-apple/issues/1).
- [x] [Deterministic performance and hitch harness](https://git.kayg.org/kayg/hermternal-apple/issues/14).
- [ ] [Notarized release credentials and key ACL setup](https://git.kayg.org/kayg/hermternal-apple/issues/25).
- [ ] [Complete history retrieval beyond 500 messages](https://git.kayg.org/kayg/hermternal-apple/issues/28).

## Known limitations in v0.0.4

- The native split view uses a hairline divider with a tonal step.
- Attachments, voice input, model controls, and reasoning controls are not implemented.
- Automatic updates are not implemented.

## Architecture

The released application is a Swift Package executable target. SwiftUI supplies the views and AppKit supplies macOS application and browser integration.

`AppModel` is the main-actor coordinator for sign-in, gateway state, chats, messages, and cache state. `AuthClient` performs the native PKCE flow, receives the loopback callback, exchanges the code for bearer credentials, and requests a WebSocket ticket. `CredentialStore` stores credentials in an owner-only file keyed by the gateway origin.

`GatewayClient` is an actor that uses `URLSessionWebSocketTask` for newline-delimited JSON-RPC calls and gateway events. `RestClient` loads session history over HTTP. `HistoryCache` is an actor that stores versioned transcript JSON files under the macOS cache directory. `MarkdownMessage` parses completed replies into prose and fenced-code segments; streaming text is shown without reparsing the whole message on every delta.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. It contains the Contributor License Agreement (CLA). By opening a pull request, you agree to the CLA terms described there.

## License

Hermternal is licensed under the [GNU General Public License, version 3 or later](LICENSE) (GPL-3.0-or-later). Forks must remain open under the same terms. Selling a fork or a build is allowed by the license terms. Copyright is held jointly by K Gopal Krishna and Aayushy Swetapragyan.

## Maintenance note

This README describes the latest release on `main`. Update it only as part of a release. Development plans live in [Forgejo issues](https://git.kayg.org/kayg/hermternal-apple/issues), not in README prose.

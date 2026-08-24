# Large conversation switching in desktop messaging clients

## Scope

This note records public, first-party evidence for Telegram Desktop, Signal Desktop, Discord, Slack, iMessage, Zulip, and Beeper.

The focus is message storage, message loading, virtualization, row reuse, caching, conversation switching, API names, and exact timings.

The research date is 2026-08-24.

`Not documented` means that the reviewed first-party sources did not state the behavior. It does not prove that the product lacks the behavior.

## Comparison

| Product | Documented message storage | Documented large-list mechanism | Documented cache or switch mechanism | Exact values or API names |
| --- | --- | --- | --- | --- |
| Telegram Desktop | In-memory `HistoryItem` objects, history blocks, and `Data::HistoryMessages`; local storage uses `Storage::Cache::Database`. | History blocks, older slices, view removal, and view replacement are present. Row reuse is not stated. | `showAtMsgId` restores a conversation position. | `History::addNewMessage`, `addCreatedOlderSlice`, `viewReplaced`; no switch timing found. |
| Signal Desktop | SQLite `messages` and `conversations` tables, with indexes by conversation and receive time. | The public code exposes chunked loading. Explicit row virtualization and row reuse were not found in the reviewed sources. | `MessageCache` updates message caches. | `MESSAGE_LOAD_CHUNK_SIZE = 30`; `FETCH_TIMEOUT = SECOND * 30`; reporting threshold `25 ms`. |
| Discord | Desktop storage details are not public in the reviewed sources. | Desktop route code splitting is documented. Discord documents native chat recycling in a mobile article. | Desktop uses route chunks and `makeLazy`. | Desktop core bundle was about `700 KB` in 2018. Mobile measurements include `30 ms` server switching and `10 ms` channel switching. |
| Slack | The desktop client moved messages out of browser `LocalStorage`. | No row virtualization or row reuse was documented in the reviewed engineering sources. | Lazy message history, partial cache, Flannel, and workspace-specific Redux stores are documented. | `users.counts`, `channels.history`, `conversations.history`, `rtm.start`; Slack recommends no more than `200` history results per request. |
| iMessage | Apple documents cloud storage with only recently accessed messages local when Messages in iCloud is enabled. | The Messages app implementation is not public. Virtualization and row reuse are not documented. | iCloud synchronizes message changes across devices. | Public extension APIs include `MSConversation`, `MSMessage`, and `MSSession`; no desktop switch timing found. |
| Zulip | Persistent message data uses PostgreSQL. The main tables include `Message` and `UserMessage`. | `message_list_view` keeps a window of up to `400` messages in the DOM. Row reuse is not documented. | Message list data, visible message lists, and scroll position controls are separate concepts. | `/json/messages` supports `anchor`, `num_before`, and `num_after`; no exact switch timing found. |
| Beeper | The public architecture is Matrix-based. The Desktop API exposes local message search and paged message reads. | No desktop virtualization or row reuse is documented in the reviewed first-party sources. | Beeper indexes network messages in the background. | `GET /v1/chats/{chatID}/messages`; cursors use `before` for older and `after` for newer messages; search limit maximum is `20`. |

## Telegram Desktop

### Evidence

The official repository identifies itself as the complete source code for the official Telegram Desktop client. [Repository README](https://github.com/telegramdesktop/tdesktop)

The `History` class stores message objects in `_items`, a message index in `_messages`, and history blocks in a deque. Each `HistoryBlock` stores `HistoryView::Element` objects in a vector. [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2550-L2564) [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2845-L2851) [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2918-L2925)

The source defines `History::addNewMessage`, `History::addCreatedOlderSlice`, `History::mainViewRemoved`, `History::mainViewHeightAdjusted`, and `History::viewReplaced`. These names document separate message data and history-view management. [history.cpp](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.cpp#L3307-L3368) [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2692-L2704) [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2698-L2704) [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2768-L2774)

The source preserves a conversation position with `showAtMsgId`. The exact comment is: “we save the last showAtMsgId to restore the state when switching between different conversation histories”. [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2554-L2561)

The source also names `addCreatedOlderSlice` and `startBuildingFrontBlock` for older-message loading. [history.h](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.h#L2677-L2694)

Local persistence uses the `Storage::Cache::Database` type in `localstorage.cpp`. [localstorage.cpp](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/storage/localstorage.cpp#L48-L86)

### Limits of the evidence

The reviewed source documents block and view operations. It does not state that message rows are recycled, pooled, or virtualized by a named framework.

No exact conversation-switch timing was found in the reviewed Telegram Desktop source or issue sources.

## Signal Desktop

### Evidence

Signal Desktop creates a SQLite `messages` table with `id`, `json`, `conversationId`, receive timestamps, and attachment flags. It creates `messages_conversation` over `conversationId, received_at`. The official issue tracker identifies the `@signalapp/better-sqlite3` dependency. [SQL migrations](https://github.com/signalapp/Signal-Desktop/blob/main/ts/sql/migrations/index.node.ts#L2483-L2546), [Signal issue tracker](https://github.com/signalapp/Signal-Desktop/issues/7010)

The conversation preload code imports `getConversationRangeCenteredOnMessage`, `getOlderMessagesByConversation`, and `getNewerMessagesByConversation` from `DataReader`. It defines `MESSAGE_LOAD_CHUNK_SIZE = 30`. It also defines `FETCH_TIMEOUT = SECOND * 30`, `JOB_REPORTING_THRESHOLD_MS = 25`, and `SEND_REPORTING_THRESHOLD_MS = 25`. [conversations.preload.ts](https://github.com/signalapp/Signal-Desktop/blob/main/ts/models/conversations.preload.ts#L2744-L2776)

The exact chunk constant is: `MESSAGE_LOAD_CHUNK_SIZE = 30`. [conversations.preload.ts](https://github.com/signalapp/Signal-Desktop/blob/main/ts/models/conversations.preload.ts#L2768-L2776)

`MessageModel.set` calls `window.MessageCache._updateCaches(this)`. This is the public source evidence for a message cache update path. [messages.preload.ts](https://github.com/signalapp/Signal-Desktop/blob/main/ts/models/messages.preload.ts#L363-L410)

### Limits of the evidence

The reviewed public sources document range reads, chunk size, SQLite indexes, and `MessageCache`.

They do not document a row virtualization library, a row reuse pool, or a desktop conversation-switch timing target.

## Discord

### Desktop evidence

Discord states that its desktop app uses code splitting to load code on demand. [How Discord Maintains Performance While Adding Features](https://discord.com/blog/how-discord-maintains-performance-while-adding-features)

Discord states that route components are bundled into separate Webpack chunks. It names a custom asynchronous loader, `makeLazy`, which retries failed chunk loads with increasing intervals. [How Discord Maintains Performance While Adding Features](https://discord.com/blog/how-discord-maintains-performance-while-adding-features#the-real-deal-code-splitting)

The same article reports a core startup bundle of about `700 KB` in 2018. It does not describe message storage, message row virtualization, or row reuse for desktop.

### Mobile evidence, labelled separately

Discord states that desktop uses React and mobile uses React Native. [Supercharging Discord Mobile](https://discord.com/blog/supercharging-discord-mobile-our-journey-to-a-faster-app)

A separate Discord engineering article documents a native mobile chat list. It names `recyclerlistview`, an internal virtualizing `List`, `ScrollerView`, and `FastList`. It also states that the implementation used techniques “to recycle views”. [How Discord achieves native iOS performance with React Native](https://discord.com/blog/how-discord-achieves-native-ios-performance-with-react-native#fast-list)

The mobile article reports `30 ms` for server switching and `10 ms` for channel switching with `recyclerlistview`. It reports `70–90 ms` of additional render-time reduction after the `FastList` work. These are mobile measurements, not desktop measurements. [How Discord achieves native iOS performance with React Native](https://discord.com/blog/how-discord-achieves-native-ios-performance-with-react-native#fast-list)

The 2025 mobile article states: “We implemented recycling mechanisms” and “pre-fill our recycling pool”. It reports up to a `60%` reduction in slow frames and about `12%` less memory in the mobile chat list. [Supercharging Discord Mobile](https://discord.com/blog/supercharging-discord-mobile-our-journey-to-a-faster-app#we-optimized-discords-native-chat-performance)

### Limits of the evidence

The mobile articles provide strong evidence for virtualization and reuse in mobile chat components.

They do not establish that Discord Desktop uses the same chat-list implementation.

## Slack

### Evidence

Slack’s engineering article describes a desktop refactor that deferred `channels.history` and lazy-loaded message history. It states that channel switching became possible before message history finished loading. [Making Slack Faster By Being Lazy: Part 2](https://slack.engineering/making-slack-faster-by-being-lazy-part-2/)

Slack states that the desktop client previously stored some messages in browser `LocalStorage`. It later states: “Today, we no longer store messages in LocalStorage”. [Making Slack Faster By Being Lazy: Part 2](https://slack.engineering/making-slack-faster-by-being-lazy-part-2/#ditching-message-history-from-localstorage)

The same article reports that large synchronous reads could block the browser for “several seconds”. It says the client retained drafts and UI state instead of message history. [Making Slack Faster By Being Lazy: Part 2](https://slack.engineering/making-slack-faster-by-being-lazy-part-2/#problems-synchronous-blocking-on-data-io)

Slack’s LibSlack article describes lazy loading, a partial cache, cache eviction decisions, and proactive fetching. It names LibSlack as a C++ core with generated interfaces from Djinni. [LibSlack](https://slack.engineering/libslack-the-c-library-at-the-foundation-of-our-client-application-architecture/)

Slack’s desktop rewrite uses one Redux store per workspace. The documented store contains workspace data, connectivity state, and the WebSocket for real-time updates. [Rebuilding Slack on the desktop](https://slack.engineering/rebuilding-slack-on-the-desktop/)

Slack’s API documents `conversations.history` with cursor pagination, `oldest`, `latest`, `inclusive`, and `limit`. It recommends no more than `200` results per request. [conversations.history](https://api.slack.com/methods/conversations.history)

Slack’s older architecture sources also name `users.counts`, `channels.history`, and `rtm.start`. [Making Slack Faster By Being Lazy: Part 2](https://slack.engineering/making-slack-faster-by-being-lazy-part-2/) [Flannel](https://slack.engineering/flannel-an-application-level-edge-cache-to-make-slack-scale-/)

### Limits of the evidence

The reviewed Slack sources document lazy loading and caching. They do not document message row virtualization or row reuse.

## iMessage

### Evidence

Apple Support states that, with Messages in iCloud, messages are stored in the cloud and only the most recently accessed messages are stored locally. [Keep your messages up to date with iCloud](https://support.apple.com/en-mide/guide/icloud/mma17ed475f7/icloud)

Apple states that message changes appear on every device. Apple also documents that enabling Messages in iCloud makes stored messages accessible on a Mac. [Set up iCloud for Messages](https://support.apple.com/en-au/guide/icloud/mm0de0d4528d/icloud)

Apple’s public `Messages` framework documents extension APIs. `MSConversation` represents a conversation in the Messages app. `MSMessage` and `MSSession` support interactive message content and updates. [Messages framework](https://developer.apple.com/documentation/messages) [MSConversation](https://developer.apple.com/documentation/messages/msconversation) [MSSession](https://developer.apple.com/documentation/messages/mssession)

### Limits of the evidence

Apple does not publish the Messages app source code or a desktop transcript architecture document in the reviewed sources.

The public `MSConversation`, `MSMessage`, and `MSSession` APIs are extension APIs. They are not evidence for the Messages app’s internal storage, virtualization, or row reuse.

No exact desktop conversation-switch timing was found.

## Zulip

### Evidence

Zulip documents PostgreSQL as the database for persistent data. Its message documentation identifies the `Message` and `UserMessage` tables. [Architecture overview](https://github.com/zulip/zulip/blob/main/docs/overview/architecture-overview.md) [PostgreSQL details](https://zulip.readthedocs.io/en/latest/production/postgresql.html)

Zulip separates `message_list_data`, `message_list`, and `message_list_view`. The documentation says a `message_list_view` contains “a window of up to 400 messages that is present in the DOM at the time”. [Sending messages](https://zulip.readthedocs.io/en/8.0/subsystems/sending-messages.html#message-lists)

Zulip documents `message_list_view` scroll position controls and selected-message handling. This is explicit bounded DOM rendering. The source does not call this row reuse.

Zulip issue data shows the message endpoint using `anchor`, `num_before`, and `num_after`. [Issue #11982](https://github.com/zulip/zulip/issues/11982)

Zulip’s architecture overview documents memcached for database model objects. [Architecture overview](https://github.com/zulip/zulip/blob/main/docs/overview/architecture-overview.md)

### Limits of the evidence

The reviewed sources document a bounded message window and backend caches.

They do not document row reuse or an exact conversation-switch timing.

## Beeper

### Evidence

Beeper states that its architecture is heavily based on Matrix. It states that messages from connected networks are bridged into the user’s Matrix account. [How Beeper Android Works](https://blog.beeper.com/2024/04/09/how-beeper-android-works/)

Beeper’s official Desktop API is local and runs inside Beeper Desktop. The documentation states that searches and fetches of existing chats or messages are local. [Beeper Desktop API](https://developers.beeper.com/desktop-api/)

The same documentation warns that message history may be limited because Beeper indexes network messages in the background. It says that only recent messages may be available when an account is first added. [Beeper Desktop API](https://developers.beeper.com/desktop-api/)

The official message list API is `GET /v1/chats/{chatID}/messages`. It uses cursor-based pagination. `direction=before` fetches older results, and `direction=after` fetches newer results. [List messages](https://developers.beeper.com/desktop-api-reference/resources/messages/methods/list/)

The message search API is `GET /v1/messages/search`. Its documented maximum `limit` is `20`. [Search messages](https://developers.beeper.com/desktop-api-reference/resources/messages/methods/search/)

Beeper’s 2025 Desktop beta announcement says the new desktop app is built on the Texts desktop app foundation. [New Beeper Desktop and iOS beta](https://blog.beeper.com/2025/02/24/try-out-the-new-beeper-desktop-and-ios-beta/)

### Limits of the evidence

The reviewed Beeper sources document Matrix bridging, local API access, background indexing, and cursor pagination.

They do not document desktop message row virtualization, row reuse, or a conversation-switch timing target.

## Source quality notes

The strongest direct UI evidence is from Telegram Desktop source, Signal Desktop source, Slack engineering posts, and Zulip documentation.

Discord provides detailed reuse and timing evidence, but the exact chat-list measurements are from mobile articles.

Apple and Beeper publish product and extension APIs, but they do not publish enough desktop UI internals to support claims about row reuse.

No undocumented implementation behavior is inferred in this note.

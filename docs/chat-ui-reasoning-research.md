# Chat UI reasoning and message-width conventions

Research date: 31 August 2026

Scope: how leading chat and LLM products present reasoning ("thinking") blocks, how they set message width, and what published design writing says about transcript readability.

This document records facts for a later chat-UI pass. It does not prescribe Hermternal design.

Method: first-party product docs, help articles, changelogs, GitHub source, and official blogs. Independent UX reviews and community CSS reports are marked as secondary. Live product CSS was not measured in a browser in this session.

Source classes:

- First-party: vendor docs, help, blogs, changelogs, and GitHub repositories that the vendor owns.
- Secondary: screenshot UX reviews, community CSS reports, userstyles, and independent design writing.

## Terms

- Thinking block: a UI region that shows model reasoning before or beside the answer.
- Collapsed: the block header is visible. The reasoning text is hidden.
- Expanded: the reasoning text is visible in the transcript.
- Overlay: expansion covers the transcript. The transcript does not grow.
- Push: expansion increases the message height. Later transcript content moves down.
- Measure: characters per line in a column of prose.

## A. Thinking-block UX

### Cross-product pattern

Most products that show reasoning use this pattern:

1. A header sits above the answer.
2. The header uses a label such as "Thinking", "Thought", or "Thought for N seconds".
3. The header is a disclosure control.
4. The default after generation is collapsed.
5. Expansion is in-line. Expansion pushes later content. Overlay is rare.

Official product docs rarely specify overlay versus push. In-line disclosure is the documented shape. Overlay appears only as a Gemini Android experiment.

### Comparison

| Product | Default after generation | Label / affordance | Streaming | Expand action | Auto-collapse |
| --- | --- | --- | --- | --- | --- |
| ChatGPT | Collapsed summary | "Thought for N seconds". Changing labels while the model thinks. | Summary streams during wait. Raw chain of thought is hidden. | In-line expand. First-party docs do not say overlay. | Screenshot review: collapses when thinking ends so the user can read the answer. |
| Claude.ai / Claude desktop | Collapsed expandable section | "Thinking" plus a timer. Click the section to open a summary. | API streams `thinking_delta` then `text_delta`. Product help describes a timer, then an expandable section. | In-line section above the answer. One screenshot review reports a separately scrollable panel. | Help does not say auto-collapse on answer start. The section is expandable, not always open. |
| Gemini | Visible while thinking. Hide control on mobile. | Desktop: "Show thinking" plus step labels. Mobile: "Thoughts" then "Response". Thinking Level: Standard, Extended, Deep Think. | Reasoning text can stream as generated text. Deep Think can take minutes. | Current Android UI expands in-line. A 2026 APK teardown tests a bottom-sheet overlay. | First-party docs do not state auto-collapse. Secondary: chevron hides the block. |
| Perplexity | Mixed | Deep Research: "Steps" and research progress. Reasoning models: chain of thought. Composer: "Thinking" as a mode toggle. | Official X post: transparent chain of thought. API: `<think>` then the answer. | First-party docs do not specify overlay versus push. | First-party docs do not specify auto-collapse. |
| T3 Chat | Collapsed after generation (user report) | Reasoning indicator. Users ask for "Reasoned in X seconds". Users ask to keep reasoning visible. | Reasoning streams. A completed bug: the spinner stayed active after reasoning ended. | First-party feedback implies in-line reasoning, not an overlay. | Not documented as auto-collapse. Users report they must expand the block each time. |
| LM Studio | Collapsed unless the user opts in | "Thinking" / "Thoughts" blocks. "Enable Thinking" for supported models. 0.3.8: collapsible UI element. | Parses `<think>` (and similar) during generation. API can emit `reasoning_content`. | In-line Thinking UI blocks. First-party docs do not say overlay. | Chat Appearance can auto-expand new blocks. Default is not auto-expand. |
| Open WebUI | Collapsed (`expandDetails` default false) | "Thinking..." while the model thinks. "Thought" or "Thought for N seconds" when done. Docs also say "Thought" or "Thinking". | Streaming parses tags in real time. Late reasoning is folded into the block above the answer. | In-line collapsible. Expansion uses a vertical slide. Expansion pushes content. | Maintainers rejected auto-expand-then-collapse as the only behaviour. They asked for a user option. |

### ChatGPT

OpenAI trains o-series models to use a chain of thought. OpenAI does not show the raw chain of thought in the product.

Quote from OpenAI, 12 September 2024:

> Therefore, after weighing multiple factors including user experience, competitive advantage, and the option to pursue the chain of thought monitoring, we have decided not to show the raw chains of thought to users. [...] For the o1 model series we show a model-generated summary of the chain of thought.

Source: [Learning to reason with LLMs](https://openai.com/index/learning-to-reason-with-llms/).

The same article shows a ChatGPT example labelled "Thought for 0 seconds" above the decoded answer. That label is first-party UI chrome in the o1 launch write-up.

Simon Willison records the ChatGPT UI as a summary of steps, not raw reasoning tokens. Source: [Notes on OpenAI’s new o1 chain-of-thought models](https://simonwillison.net/2024/Sep/12/openai-o1/).

KDnuggets records the disclosure label "Thought for 22 seconds". A click on that label shows the summary steps. Source: [Getting Started with OpenAI o1 Reasoning Models](https://kdnuggets.com/getting-started-with-openai-o1-reasoning-models) (13 September 2024).

Digestible UX captured ChatGPT o3-mini on 5 March 2025:

- Flashing and changing text labels signal progress.
- Short reasoning stays visible during the wait.
- The block collapses when thinking is done.
- The user must expand the block to read details.

Source: [How AI models show their reasoning process in real-time](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning) (secondary, screenshot review).

The OpenAI API does not return that reasoning text for o-series Chat Completions. Source: [O1 model, displaying intermediate reasoning](https://community.openai.com/t/o1-model-displaying-intermediate-reasoning/1151285) (OpenAI community, staff reply: "o" models do not produce reasoning output on the API).

First-party docs do not name overlay versus push. The documented control is an expandable summary in the message. That shape is in-line push.

### Claude.ai and Claude desktop

Anthropic help covers model, effort, and thinking in one menu next to the send button. The same article describes the product UI for Claude, not only the API.

When thinking is on, the user sees:

- A "Thinking" indicator with a timer.
- An expandable "Thinking" section above the response.

Quote:

> Click the "Thinking" section to view Claude's thought process summary and problem-solving approach.

If safety systems redact part of the process, the UI says the rest of the thought process is not available.

Source: [Change the model, effort, and thinking settings](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings).

Claude 3.7 Sonnet made the thought process visible in raw form. Anthropic listed trust, alignment research, and interest as reasons. Anthropic also listed faithfulness limits and safety risks. Source: [Claude's extended thinking](https://www.anthropic.com/news/visible-extended-thinking) (24 February 2025).

Claude 4 added thinking summaries. A smaller model condenses long thought processes. Anthropic says summarization is needed about 5 percent of the time. Most thought processes are short enough to show in full. Source: [Introducing Claude 4](https://www.anthropic.com/news/claude-4) (22 May 2025).

The Messages API returns `thinking` blocks before `text` blocks. Streaming emits `thinking_delta` events, then `text_delta` events. `display: "summarized"` returns a summary. `display: "omitted"` returns an empty `thinking` field and no `thinking_delta` events. Newest models default `display` to `"omitted"`. The product help still describes an expandable "Thinking" section when thinking is on. Source: [Thinking](https://platform.claude.com/docs/en/build-with-claude/thinking).

Digestible UX captured Claude 3.7 Sonnet on 5 March 2025:

- The full reasoning is not shown by default.
- The user can expand it.
- The reasoning section is separately scrollable.
- The section uses bullets.

Source: [How AI models show their reasoning process in real-time](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning) (secondary). Separately scrollable is a screenshot observation. Help does not confirm a nested scroller.

### Gemini

Google documents Thinking Level in Gemini Apps:

- Standard: default. Faster responses.
- Extended: longer reasoning before a response.
- Deep Think: Ultra only. Maximum parallel reasoning. Queries can take a few minutes.

Source: [Gemini Apps limits and upgrades](https://support.google.com/gemini/answer/16275805).

Deep Think on computer:

1. Select Pro.
2. Select Thinking Level Deep Think.
3. Submit.

The user can leave the chat. Gemini notifies when the response is ready.

Source: [Use Deep Think in Gemini Apps](https://support.google.com/gemini/answer/16345172).

Google describes Deep Think as parallel thinking: generate many ideas, revise them, then answer. Source: [Gemini 2.5: Deep Think is now rolling out](https://blog.google/products-and-platforms/products/gemini/gemini-2-5-deep-think/) (1 August 2025).

Google on 2.0 Flash Thinking Experimental (5 February 2025):

> 2.0 Flash Thinking Experimental shows its thought process so you can see why it responded in a certain way, what its assumptions were, and trace the model's line of reasoning.

Source: [Access the latest 2.0 experimental models in the Gemini app](https://blog.google/feed/gemini-app-experimental-models/).

9to5Google (6 February 2025, secondary) records the consumer app chrome:

- Desktop: "Show thinking" plus step labels such as "Identify the question’s scope".
- Mobile: a "Thoughts" section, then "Response".
- The app streams the text in real time. The stream is faster than a person can read.
- The user can tap the chevron to hide the block.

Source: [Gemini 2.0 Flash Thinking and 2.0 Pro Experimental rolling out to Gemini app](https://9to5google.com/2025/02/06/gemini-app-2-0-flash-thinking-2-0-pro-experimental/).

Android Authority teardown of Google app 17.10.54 (18 March 2026):

- Current UI: expand reasoning in-line above the answer.
- Test UI: tap "Show thinking" to open a bottom sheet. The sheet also shows model details.

Source: [Google is quietly testing a Discover tab in Gemini](https://www.androidauthority.com/gemini-ui-changes-apk-teardown-3650199/) (secondary APK teardown). Overlay is experimental, not confirmed as shipping.

Digestible UX captured Gemini 2.0 Flash Thinking Experimental on 5 March 2025:

- A throbber and a "Thinking..." label.
- Continuously generated text.
- The view does not auto-scroll.
- Completion of the thought process is hard to see.

Source: [How AI models show their reasoning process in real-time](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning) (secondary).

First-party Gemini Apps help does not state collapsed-by-default, auto-collapse, or overlay versus push for the thinking block.

### Perplexity

Perplexity documents two related surfaces.

Deep Research shows research progress and steps, not a hidden thought log. Independent write-ups of the official help and blog use "Steps" and "Research Progress". The official blog URL returned a bot-check page in this session. Cite the help and blog URLs as first-party pages: [What's new in Advanced Deep Research](https://www.perplexity.ai/help-center/en/articles/13600190-what-s-new-in-advanced-deep-research.html), [Introducing Perplexity Deep Research](https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research).

For reasoning models, Perplexity posted on 27 January 2025 that DeepSeek R1 is on Perplexity with "transparent chain of thought into model's reasoning" and a Pro Search reasoning mode selector next to OpenAI o1. Source: [Perplexity on X](https://x.com/perplexity_ai/status/1883913343854923989) (first-party post; fetch of the page returned 403 in this session).

The Sonar API documents that `sonar-reasoning-pro` outputs a `<think>` section of reasoning tokens, then the answer. `response_format` does not strip those tokens. Source: [Sonar Reasoning Pro](https://docs.perplexity.ai/docs/sonar/models/sonar-reasoning-pro).

A September 2025 UI leak reports a compact selector where "Thinking" is a toggle. Source: TestingCatalog on Threads (secondary).

First-party material confirms visible chain of thought and a Thinking mode control. It does not document collapsed-by-default, auto-collapse, or overlay versus push.

### T3 Chat

T3 Chat does not publish a thinking-block spec. First-party evidence is the product feedback board.

- Bug, status Completed: with Qwen and DeepSeek R1, the reasoning indicator kept spinning after reasoning ended and while the answer streamed. The requester asked for a label such as "Reasoned in X seconds". Source: [UI: Reasoning Indicator Stays Active Post-Reasoning](https://feedback.t3.chat/p/ui-reasoning-indicator-stays-active-post-reasoning).
- Feature request: a reasoning toggle in the prompt box, instead of a model-tab switch to a reasoning variant. Source: [Reasoning Button](https://feedback.t3.chat/p/reasoning-button).
- Feature request, status Gathering Interest (76 upvotes): "can you add toggle to chat so we can keep the reasoning tokens visible. Expanding them every time is a pain." That wording implies the block collapses after generation and that expansion is manual. Source: [Show Reasoning Text: Toggle](https://feedback.t3.chat/p/show-reasoning-text-toggle).
- Feedback board search hit: users asked to collapse reasoning from the bottom of a long reasoning block. Source: [T3 Chat feedback](https://feedback.t3.chat/en).

Those items imply:

- T3 Chat has a reasoning indicator during generation.
- Reasoning can be long enough that the header is off-screen.
- After generation, users expand the block to read it.
- The product does not ship a keep-open toggle (that toggle is a request).

A separate request asks to collapse whole user and assistant messages. That request is not the thinking block. Status: Gathering Interest. Source: [Collapsible Chat Messages](https://feedback.t3.chat/p/collapsible-chat-messages).

Do not treat pingdotgg/t3code issue #287 as T3 Chat. That issue is T3 Code.

### LM Studio

LM Studio 0.3.8 (first-party changelog):

> New: DeepSeek R1 thought process will be contained in a collapsible UI element

Source: [LM Studio 0.3.8](https://lmstudio.ai/blog/lmstudio-v0.3.8).

LM Studio 0.3.9 (build 3) adds a Chat Appearance option:

> New: Add a Chat Appearance option to auto-expand newly added Thinking UI blocks

The same release notes:

- Font size in Chat Appearance did not scale text in the Thoughts block. That bug was fixed.
- Equations inside model thinking blocks could generate empty space. That bug was fixed.

Source: [LM Studio 0.3.9](https://lmstudio.ai/blog/lmstudio-v0.3.9).

Auto-expand is an option. The option exists because new blocks are not auto-expanded by default.

LM Studio parses DeepSeek-style `<think>` content. A later 0.3.9 build adds experimental `reasoning_content` in chat completions. Source: same changelog.

The DeepSeek R1 blog shows a collapsible thinking section in a local chat screenshot ("Click to expand/collapse") around the `<think>` payload. Source: [DeepSeek R1: open source reasoning model](https://lmstudio.ai/blog/deepseek-r1).

Supported catalog models can show an "Enable Thinking" control. Sideloaded GGUF files may omit that control if metadata is missing. Sources: LM Studio bug tracker issues [2052](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2052), [1713](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1713) (first-party tracker).

First-party material does not state overlay. The Thinking UI is a block in the chat transcript (push).

### Open WebUI

Official docs:

> Open WebUI automatically: 1. Detects these tags in the model's output stream. 2. Extracts the content between the tags. 3. Renders the extracted content in a collapsible UI element labeled "Thought" or "Thinking". This keeps the main chat interface clean while still giving you access to the model's internal processing.

Default tag pairs include `<think>`, `<thought>`, `<reasoning>`, and `<|begin_of_thought|>`.

Streaming: tokens are parsed as they arrive. Reasoning that arrives after the answer has started is folded into the thinking block above the answer. Empty reasoning metadata does not open an empty block.

Non-streaming: the parser often fails. Raw tags then appear in the answer.

Source: [Reasoning and Thinking Models](https://docs.openwebui.com/features/chat-conversations/chat-features/reasoning-models/).

Settings > Interface includes `expandDetails`, labelled "Always Expand Details". The built-in default is `false`. Source: [Default Interface Settings](https://docs.openwebui.com/features/administration/interface-defaults/).

The Svelte renderer binds that setting:

```
open={$settings?.expandDetails ?? false}
```

Source: [MarkdownTokens.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Messages/Markdown/MarkdownTokens.svelte) (`main` at research time). Empty details stay closed (`open={false}`).

`Collapsible.svelte` is an in-flow disclosure. Expansion uses Svelte `slide` on the Y axis. There is no `position: absolute` overlay. Source: [Collapsible.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/common/Collapsible.svelte).

For `attributes.type === 'reasoning'`, the header text is:

- "Thinking..." while the block is not done.
- "Thought" when done and duration is missing.
- "Thought for less than a second" / "Thought for {{DURATION}} seconds" / "Thought for {{DURATION}}" when duration is present.

Source: same `Collapsible.svelte` file.

Collapsed default is also first-party community evidence on the Open WebUI repo:

> By default, the chain-of-thought is collapsed and requires a click to expand.

Source: [Discussion #9706](https://github.com/open-webui/open-webui/discussions/9706) (9 February 2025).

PR #9879 tried to expand the block during reasoning and collapse it when done. The PR was closed. Source: [feat: Automatically expand and collapse reasoning blocks](https://github.com/open-webui/open-webui/pull/9879).

PR #10625 tried the same unfold-before-completion behaviour. Maintainer Tim (tjbck):

> We might want to make this a toggleable option, some users do not necessarily want to see the reasoning content

Source: [enh: Unfold the folding control before completion](https://github.com/open-webui/open-webui/pull/10625).

Workarounds in #9706 edit compiled `Collapsible.*.js` (`open:o=!1` to `open:o=!0`). That confirms the shipped default is closed.

A native "Think" composer button is not built in. Maintainers say provider differences make a universal toggle impossible. Admins can add a filter. Source: [Discussion #11006](https://github.com/open-webui/open-webui/discussions/11006) (collaborator comment, 12 March 2026).

### Adjacent products (not in the requested set)

Digestible UX also captured Grok 3 and DeepSeek R1 on 5 March 2025:

- Grok: scrolling snippets during wait. Collapse when done. Clear expand cue. Time counter.
- DeepSeek: "Thinking..." plus a throbber. Reasoning stays expanded and grows downward (maximum transparency, high overload).

Source: [How AI models show their reasoning process in real-time](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning).

Those two products mark the ends of the transparency range. ChatGPT and Claude sit toward low overlay. DeepSeek sits toward full push.

## B. Message width and measure

### Cross-product pattern

Serious LLM chat UIs converge on:

- A centered transcript column.
- A max width near 720–768 CSS pixels on desktop for closed products (secondary measurements).
- Assistant prose as a full-column document, not an SMS bubble.
- User text as a distinct, often narrower, often right-aligned block.
- No first-party full-width toggle in ChatGPT, Claude, or Gemini. Users add CSS or extensions.
- Open WebUI ships a first-party Widescreen Mode setting. The composer column is `max-w-[58rem]` unless that setting is on.

Setproduct (May 2026, secondary field measurements of daily-driver apps):

> Use a comfortable max-width — Claude.ai uses around 768 pixels, ChatGPT around 768, Perplexity around 720. Beyond that, long answers become unreadable.

Setproduct also records the two-pane desktop standard: history rail, center column capped at about 720–768 pixels, optional artifact pane. Source: [Designing AI chat interfaces](https://www.setproduct.com/blog/ai-chat-interface-ui-design).

### ChatGPT

An OpenAI community feature request (September 2024) reports live ChatGPT conversation classes:

- `md:max-w-3xl` (Tailwind `3xl` = 48rem = 768px)
- `lg:max-w-[40rem]` (640px)
- `xl:max-w-[48rem]` (768px)

The requester asked for a user-controlled max width. Replies describe leftover whitespace on 27-inch monitors and third-party "WideChat" extensions that widen ChatGPT, Claude, Gemini, and other chats.

Source: [Allow Users to Customize Chat Window Width in ChatGPT](https://community.openai.com/t/allow-users-to-customize-chat-window-width-in-chatgpt/958512) (community CSS report, not an OpenAI design spec).

A related first-party community request: [Please let us set chat to full screen width](https://community.openai.com/t/please-let-us-set-chat-to-full-screen-width/1028962).

OpenAI does not publish an official measure for ChatGPT. The community values match Setproduct's 768px figure. Class names change between releases. Treat any pixel number as approximate.

User versus assistant chrome is not specified in OpenAI docs. Independent UI writing describes ChatGPT as a document column with distinct user blocks, not iMessage bubbles. Source: Setproduct, cited above. A third-party pixel clone describes a right-aligned user bubble at about 70 percent of column width. Source: [ChatGPT Clone Example](https://www.assistant-ui.com/examples/chatgpt) (secondary clone, not live CSS).

### Claude.ai

Anthropic does not publish a pixel max-width. Setproduct measures about 768px.

A userstyle that targets live `claude.ai/chat/` overrides two classes:

- `.max-w-3xl` (Tailwind 48rem = 768px)
- `.max-w-[75ch]` (a tighter prose cap)

Source: [Claude.ai - Wider chat bubbles](https://userstyles.world/style/11058/claude-ai-wider-chat-bubbles) (secondary; the selectors are the evidence, not the override values).

A third-party clone describes assistant text as full-width plain serif with no bubble, and user text as `rounded-2xl bg-[#E5E0D6] max-w-[80%]`. Source: [Claude Clone](https://www.assistant-ui.com/examples/claude) (secondary clone).

Claude help does not document a wide-layout toggle.

### Gemini

Google does not publish a pixel max-width for the Gemini Apps transcript. Setproduct groups Gemini with the two-pane, capped-column pattern. WideChat lists Gemini as a target of full-width CSS. Source: the ChatGPT community thread above.

A Firefox add-on listing says it toggles max-width between 1200px and a "hardcoded" 760px on gemini.google.com. Source: [Google Gemini Wide Content](https://addons.mozilla.org/en-US/firefox/addon/gemini-wide-content-toggle/) (secondary marketing copy). Treat 760px as unverified.

A third-party clone describes assistant replies as full-width markdown with no bubble, and user turns as `rounded-3xl bg-[#f2f0f0] max-w-[75%]`. Source: [Gemini Clone](https://www.assistant-ui.com/examples/gemini) (secondary clone).

### Perplexity

Setproduct measures about 720px. Perplexity uses citations and related chips. Those extra columns compete with measure. First-party docs do not state a max-width.

A userstyle targets `.max-w-threadWidth` and widens it. It does not record the default value. Source: [Improve perplexity chat maximum width](https://userstyles.world/style/15699/improve-perplexity-chat-maximum-width) (secondary).

### T3 Chat

No first-party width spec was found. T3 Chat is a web chat with a centered transcript. Exact `max-width` is undocumented. Do not invent a pixel value. The T3 Chat FAQ does not mention layout width. Source: [T3 Chat FAQ](https://t3.chat/faq).

### LM Studio

LM Studio is a desktop app. The 0.3.9 notes mention Chat Appearance (font size, auto-expand Thinking). They do not mention a transcript max-width or a wide-layout toggle.

A user issue on the vendor tracker uses "chat bubble" as the name of the message unit. Source: [lmstudio-bug-tracker#1498](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1498) (user text on a first-party tracker). Official chat-management docs do not document width. Source: [Manage chats](https://lmstudio.ai/docs/app/basics/chat).

### Open WebUI

Users reported a hard-coded narrow conversation column that wasted 4K and ultrawide screens and made code hard to read. They asked for width that tracks available space, or a max-width setting.

Maintainers already had a related issue. They shipped fullscreen mode (PR #751) as a wide extreme. Fullscreen used the full browser width. Users still asked for a middle width.

Source: [Output limited to a very narrow column](https://github.com/open-webui/open-webui/issues/750) (16 February 2024), with maintainer screenshots of default versus fullscreen.

Current first-party interface settings (`main` at research time):

- `chatBubble` ("Chat Bubble UI"): built-in default `true`. Description: "Render messages in compact bubble containers."
- `widescreenMode` ("Widescreen Mode"): built-in default `false`. Description: "Use a wider chat layout on large displays."

Source: [Default Interface Settings](https://docs.openwebui.com/features/administration/interface-defaults/), [InterfaceSettings.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/common/InterfaceSettings.svelte).

Composer column (`MessageInput.svelte`): `max-w-[58rem]` when widescreen mode is off. `max-w-full` when widescreen mode is on. The empty-state placeholder also uses `max-w-[58rem]`. Sources: [MessageInput.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/MessageInput.svelte), [Placeholder.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Placeholder.svelte).

The message list itself is `max-w-full` of the chat pane (`Chat.svelte` `#messages-container`). Assistant replies use `w-full` with no bubble background. User messages, when `chatBubble` is true, use `rounded-3xl max-w-[90%]` and right alignment. Sources: [Chat.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Chat.svelte), [ResponseMessage.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Messages/ResponseMessage.svelte), [UserMessage.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Messages/UserMessage.svelte).

Open WebUI is the only product in this set with inspectable source for both bubble split and a native wide-layout toggle.

## C. Published design writing on transcript readability

### Line length (measure)

Bringhurst, as applied to the web by Richard Rutter:

> Anything from 45 to 75 characters is widely regarded as a satisfactory length of line for a single-column page set in a serifed text face in a text size. The 66-character line (counting both letters and spaces) is widely regarded as ideal. For multiple column work, a better average is 40 to 50 characters.

Rutter recommends `em`-based width so measure stays stable when the user changes text size.

Source: [Choose a comfortable measure](https://webtypography.net/2.1.2).

Butterick:

> Aim for an average line length of 45–90 characters, including spaces.

Butterick also gives an alphabet test: two to three alphabets on a line.

Source: [Line length](https://practicaltypography.com/line-length.html).

Laura Franz (Smashing Magazine, 2014):

- Print: 45–75 characters.
- Web: 45–85 characters is acceptable.
- 65 characters is a common "perfect" figure.
- Long lines cause fatigue and doubling (re-reading the same line).
- Short lines break units that readers take together.
- Do not shrink or enlarge type only to hit measure. Keep a comfortable font size, then adjust column width.
- Line height near 150 percent of font size. Small type needs more line height.

Source: [Size Matters: Balancing Line Length And Font Size In Responsive Web Design](https://www.smashingmagazine.com/2014/09/balancing-line-length-font-size-responsive-web-design/).

Material Design (M1, no longer maintained) cites Baymard:

> You should have around 60 characters per line if you want a good reading experience.

The same page quotes Baymard on lines that are too wide (hard to focus, hard to find the next line) and too narrow (the eye travels back too often). Source: [Typography - Style - Material Design (M1)](https://m1.material.io/style/typography.html).

Nielsen Norman Group does not treat 50–75 characters as its primary guideline in the articles fetched here. NN/g states:

- Users read only about 28 percent of the words on an average page visit.
- Users scan. The F-pattern is a default when the page is a wall of text.
- First lines and the left edge get more fixations.
- Format with headings, bullets, bold, and front-loaded information.

Sources: [Legibility, Readability, and Comprehension](https://www.nngroup.com/articles/legibility-readability-comprehension/), [F-Shaped Pattern of Reading](https://www.nngroup.com/articles/f-shaped-pattern-reading-web-content/).

Baymard's public index lists "Readability: The Optimal Line Length" as a research article. The article body did not load in this session (the fetch returned the Baymard llms.txt index). Do not quote a Baymard character count from that page. Material Design quotes Baymard as about 60 characters per line. URL: [Readability: The Optimal Line Length](https://baymard.com/blog/line-length-readability).

WCAG 2.2 Success Criterion 1.4.8 Visual Presentation (Level AAA) requires a mechanism so that width is no more than 80 characters or glyphs (40 if CJK). Content does not have to use those values by default. The requirement is that a mechanism exists (browser or author). Source: [WCAG 2.2, 1.4.8](https://www.w3.org/TR/WCAG22/#visual-presentation).

### Platform readable width

Apple:

> This layout guide defines an area that can easily be read without forcing users to move their head to track the lines.

Rules:

1. The guide never extends beyond the layout margin guide.
2. The guide is vertically centered in the layout margin guide.
3. Width is equal to or less than the readable width for the current Dynamic Type size.

Apple tells developers to use the guide for a single column of text. Apple does not give one universal pixel max.

Source: [readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).

Apple HIG typography also recommends loose leading for wide columns or long passages. Source: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).

macOS does not support Dynamic Type. Source: same HIG page. A companion file in this repo records the Apple type metrics: [apple-native-typography-research.md](apple-native-typography-research.md).

### AI chat as a document, not a messenger

Setproduct (29 May 2026) treats AI chat as its own anatomy. Points that bear on transcript layout:

- AI chat is not Slack and not an Intercom bot. Replies are long-form and streamed.
- Thinking is "a collapsible section above the answer. Default collapsed." Labels must be honest: Thinking, Reasoning, or Searching the web.
- Message stream max-width: about 720–768px.
- Sustained reading: about 65–72 characters per line. WCAG 2.2 is cited for no more than 80 characters per line.
- Line-height around 1.6.
- Anti-pattern: SMS bubble shapes. Claude.ai, ChatGPT, and Cursor use flat, full-width (of the column) assistant messages with light differentiation.
- FAQ: "Full-width is the current best practice for serious AI chat. Bubbles signal messenger and undermine the tool framing."
- Checklist: cap the stream between 65 and 80 characters per line.

Source: [Designing AI chat interfaces](https://www.setproduct.com/blog/ai-chat-interface-ui-design).

Digestible UX (6 March 2025) on reasoning UX:

- More transparency is not always better UX.
- Progress indicators reduce perceived wait ("elevator mirror").
- Users want the answer. Reasoning is secondary.
- ChatGPT: unobtrusive. Collapses when done.
- Claude: structured, low overload, expand on demand.
- DeepSeek: maximum transparency, easy to overwhelm.

Source: [How AI models show their reasoning process in real-time](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning).

Ish Jindal (UX Collective, 24 July 2017) writes about scripted chatbots, not LLM transcripts. That article argues for short SMS-length bursts because messenger bubbles waste width and force height. That advice conflicts with long-form LLM answers. Use it only as a contrast: classic chatbot measure is not LLM transcript measure. Source: [Why Message Length Matters](https://uxdesign.cc/chatbot-building-best-practices-why-message-length-matters-e951bed1b550).

### What this writing does not settle

- No first-party vendor publishes "assistant is full-column, user is bubbled" as a written rule. That split is observed in products and in independent UI writing. Open WebUI source is the one inspectable implementation of that split.
- No first-party vendor publishes a character-per-line budget for ChatGPT, Claude, or Gemini. Claude's live CSS includes `max-w-[75ch]` (secondary userstyle observation).
- WCAG 2.2 Success Criterion 1.4.8 is AAA, not AA. Setproduct cites it as a reading cap. The criterion asks for a mechanism, not a fixed default.
- Overlay thinking (Gemini bottom sheet) is an experiment. In-line collapsed-by-default is the documented majority.

## Source limits

- This session did not instrument ChatGPT, Claude, Gemini, Perplexity, T3 Chat, or LM Studio in a browser. Pixel values other than community CSS, userstyles, and Setproduct measurements are not verified here.
- Gemini Apps help describes thinking levels. It does not describe the thinking-block chrome. The Google blog confirms that thinking models "show [their] thought process".
- T3 Chat has no public design spec. Feedback posts are the first-party record.
- Perplexity's marketing site blocked automated fetch. The X post and API docs are the load-bearing first-party sources for reasoning UI.
- Open WebUI UI defaults can change between releases. The `expandDetails` default and `Collapsible.svelte` labels were read from `main` on 31 August 2026.
- Digestible UX is a 5 March 2025 screenshot review. Product UIs have changed since that date (Claude summaries, Gemini thinking levels, ChatGPT model mix).
- Do not mix T3 Code (`pingdotgg/t3code`) with T3 Chat.

## Sources

### First-party

- [OpenAI, Learning to reason with LLMs](https://openai.com/index/learning-to-reason-with-llms/)
- [Anthropic, Claude's extended thinking](https://www.anthropic.com/news/visible-extended-thinking)
- [Anthropic, Introducing Claude 4](https://www.anthropic.com/news/claude-4)
- [Anthropic help, Change the model, effort, and thinking settings](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings)
- [Claude API, Thinking](https://platform.claude.com/docs/en/build-with-claude/thinking)
- [Google, Gemini Apps limits and upgrades](https://support.google.com/gemini/answer/16275805)
- [Google, Use Deep Think in Gemini Apps](https://support.google.com/gemini/answer/16345172)
- [Google, Gemini 2.5 Deep Think](https://blog.google/products-and-platforms/products/gemini/gemini-2-5-deep-think/)
- [Google, 2.0 experimental models in the Gemini app](https://blog.google/feed/gemini-app-experimental-models/)
- [Perplexity, Sonar Reasoning Pro](https://docs.perplexity.ai/docs/sonar/models/sonar-reasoning-pro)
- [Perplexity, DeepSeek R1 / transparent CoT (X)](https://x.com/perplexity_ai/status/1883913343854923989)
- [T3 Chat feedback, reasoning indicator](https://feedback.t3.chat/p/ui-reasoning-indicator-stays-active-post-reasoning)
- [T3 Chat feedback, reasoning button](https://feedback.t3.chat/p/reasoning-button)
- [T3 Chat feedback, show reasoning text toggle](https://feedback.t3.chat/p/show-reasoning-text-toggle)
- [T3 Chat feedback, collapsible messages](https://feedback.t3.chat/p/collapsible-chat-messages)
- [LM Studio 0.3.8 changelog](https://lmstudio.ai/blog/lmstudio-v0.3.8)
- [LM Studio 0.3.9 changelog](https://lmstudio.ai/blog/lmstudio-v0.3.9)
- [LM Studio, DeepSeek R1](https://lmstudio.ai/blog/deepseek-r1)
- [Open WebUI, Reasoning and Thinking Models](https://docs.openwebui.com/features/chat-conversations/chat-features/reasoning-models/)
- [Open WebUI, Default Interface Settings](https://docs.openwebui.com/features/administration/interface-defaults/)
- [Open WebUI MarkdownTokens.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Messages/Markdown/MarkdownTokens.svelte)
- [Open WebUI Collapsible.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/common/Collapsible.svelte)
- [Open WebUI discussion #9706](https://github.com/open-webui/open-webui/discussions/9706)
- [Open WebUI PR #9879](https://github.com/open-webui/open-webui/pull/9879)
- [Open WebUI PR #10625](https://github.com/open-webui/open-webui/pull/10625)
- [Open WebUI issue #750](https://github.com/open-webui/open-webui/issues/750)
- [Open WebUI MessageInput.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/MessageInput.svelte)
- [Open WebUI UserMessage.svelte](https://github.com/open-webui/open-webui/blob/main/src/lib/components/chat/Messages/UserMessage.svelte)
- [Apple, readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide)
- [Apple HIG, Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [W3C, WCAG 2.2 Visual Presentation](https://www.w3.org/TR/WCAG22/#visual-presentation)

### Secondary

- [Digestible UX, How AI models show their reasoning](https://www.digestibleux.com/p/how-ai-models-show-their-reasoning)
- [Simon Willison, Notes on o1](https://simonwillison.net/2024/Sep/12/openai-o1/)
- [KDnuggets, Getting started with o1](https://kdnuggets.com/getting-started-with-openai-o1-reasoning-models)
- [OpenAI community, chat window width](https://community.openai.com/t/allow-users-to-customize-chat-window-width-in-chatgpt/958512)
- [9to5Google, Gemini 2.0 Flash Thinking in the Gemini app](https://9to5google.com/2025/02/06/gemini-app-2-0-flash-thinking-2-0-pro-experimental/)
- [Android Authority, Gemini UI teardown](https://www.androidauthority.com/gemini-ui-changes-apk-teardown-3650199/)
- [Setproduct, Designing AI chat interfaces](https://www.setproduct.com/blog/ai-chat-interface-ui-design)
- [Claude.ai userstyle, max-w-3xl and max-w-[75ch]](https://userstyles.world/style/11058/claude-ai-wider-chat-bubbles)
- [Butterick, Line length](https://practicaltypography.com/line-length.html)
- [Rutter, Choose a comfortable measure](https://webtypography.net/2.1.2)
- [Franz, Line length and font size](https://www.smashingmagazine.com/2014/09/balancing-line-length-font-size-responsive-web-design/)
- [Material Design M1, Typography (quotes Baymard ~60 cpl)](https://m1.material.io/style/typography.html)
- [NN/g, Legibility, readability, comprehension](https://www.nngroup.com/articles/legibility-readability-comprehension/)
- [NN/g, F-shaped pattern](https://www.nngroup.com/articles/f-shaped-pattern-reading-web-content/)
- [Jindal, Why message length matters](https://uxdesign.cc/chatbot-building-best-practices-why-message-length-matters-e951bed1b550)

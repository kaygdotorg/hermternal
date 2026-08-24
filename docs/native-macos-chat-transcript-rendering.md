# Native macOS approaches for large chat transcripts

Research date: 2026-08-24

## Conclusion

Use `NSTableView` when each message needs its own native view, actions, selection, or attachments. Use cached row heights and reuse views.

Use `NSCollectionView` when the transcript needs reusable items, sections, supplementary views, or a custom layout. Use `estimatedItemSize` while the layout computes actual item sizes.

Use one `NSTextView` with TextKit 2 when the transcript is mainly continuous text. TextKit 2 lays out the active viewport and supports custom rendering surfaces.

Use Core Text when you need a custom drawing surface and full control over measurement. This option requires more work for selection, accessibility, links, and interactive attachments.

These are implementation recommendations from the documented API behavior. They are not Apple product requirements.

## Apple API findings

### `NSTableView`

Apple describes a table view as rows and columns backed by a data source. A view-based table can use complex `NSView` content. View-based tables are available from macOS 10.7.

Sources: [NSTableView](https://developer.apple.com/documentation/appkit/nstableview), [NSTableCellView](https://developer.apple.com/documentation/appkit/nstablecellview).

Use these APIs for message rows:

- `NSTableView`
- `NSTableViewDataSource`
- `NSTableViewDelegate`
- `tableView(_:viewFor:row:)`
- `makeView(withIdentifier:owner:)`
- `NSTableCellView`
- `NSTableRowView`
- `rowView(atRow:makeIfNecessary:)`

Apple recommends that `tableView(_:viewFor:row:)` call `makeView(withIdentifier:owner:)`. That call attempts to return a view from the reuse queue. The table sets the returned view frame.

Source: [tableView(_:viewFor:row:)](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview%28_%3Aviewfor%3Arow%3A%29).

For variable message heights, implement `tableView(_:heightOfRow:)`. The returned height must be greater than `0`. The height excludes intercell spacing. Apple says the table can cache returned values, so the method must be efficient.

Do not create a row view or calculate table geometry inside `tableView(_:heightOfRow:)`. Apple documents these calls as recursion and hang risks.

When a message height changes, call `noteHeightOfRows(withIndexesChanged:)`. Apple says this method immediately retiles the table when the delegate supplies row heights. It animates for view-based tables unless an `NSAnimationContext` duration of `0` disables the animation.

Sources: [tableView(_:heightOfRow:)](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview%28_%3AheightOfRow%3A%29), [noteHeightOfRows(withIndexesChanged:)](https://developer.apple.com/documentation/appkit/nstableview/noteheightofrows%28withindexeschanged%3A%29).

`usesAutomaticRowHeights` is a `Bool` property. It tells the table to use Auto Layout to calculate row heights.

`rowHeight` has a documented default of `16.0` points. This value applies only when `rowSizeStyle` is `NSTableViewRowSizeStyleCustom`.

Sources: [usesAutomaticRowHeights](https://developer.apple.com/documentation/appkit/nstableview/usesautomaticrowheights), [rowHeight](https://developer.apple.com/documentation/appkit/nstableview/rowheight).

Recommended transcript pattern:

1. Store message data outside the table.
2. Use one reusable view for each message row type.
3. Cache the measured height by message ID, available width, text revision, and display style revision.
4. Return the cached height from `tableView(_:heightOfRow:)`.
5. Invalidate only changed rows with `noteHeightOfRows(withIndexesChanged:)`.

### `NSCollectionView`

Apple describes `NSCollectionView` as an ordered collection of data items with customizable layouts. The modern architecture is recommended for macOS 10.11 and later.

The data source creates items on demand. `NSCollectionViewItem` objects can be recycled and reused for new data. Apple says not to store references to item objects.

Use these APIs:

- `NSCollectionView`
- `NSCollectionViewDataSource`
- `NSCollectionViewDelegate`
- `NSCollectionViewItem`
- `register(_:forItemWithIdentifier:)`
- `makeItem(withIdentifier:for:)`
- `NSCollectionViewFlowLayout`
- `NSCollectionViewDelegateFlowLayout`
- `collectionView(_:layout:sizeForItemAt:)`

Sources: [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview), [NSCollectionViewItem](https://developer.apple.com/documentation/appkit/nscollectionviewitem).

`NSCollectionViewFlowLayout.estimatedItemSize` has type `NSSize`. Its default is `NSZeroSize`. A non-zero estimate lets the flow layout defer some size calculations. The layout uses the estimate for offscreen items until it calculates an actual size.

If no estimate and no delegate size are available, `itemSize` supplies the size. Apple documents the default `itemSize` as `(50.0, 50.0)` points.

Sources: [estimatedItemSize](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout/estimateditemsize), [itemSize](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout/itemsize), [NSCollectionViewFlowLayout](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout).

`collectionView(_:layout:sizeForItemAt:)` must return width and height values greater than `0`. For vertical scrolling, the item width should not exceed the available collection width after insets.

Source: [collectionView(_:layout:sizeForItemAt:)](https://developer.apple.com/documentation/appkit/nscollectionviewdelegateflowlayout/collectionview%28_%3Alayout%3Asizeforitemat%3A%29).

Recommended transcript pattern:

1. Use a vertical `NSCollectionViewFlowLayout`.
2. Set a useful width and height estimate in `estimatedItemSize`.
3. Return actual sizes from `collectionView(_:layout:sizeForItemAt:)` when the size is known cheaply.
4. Register message item classes with `register(_:forItemWithIdentifier:)`.
5. Reset every item during configuration because the item can contain data from a previous message.

`NSCollectionView` is a strong fit when the transcript has multiple item types, date separators, typing indicators, or supplementary views. A one-column collection view adds layout machinery that a simple table does not need.

### TextKit 2

Apple’s TextKit documentation says that `NSTextView` exposes `textLayoutManager`, `textContainer`, and `textStorage`. The modern `textLayoutManager` uses TextKit 2. The legacy `layoutManager` uses TextKit 1. Apple recommends the modern manager for better performance and international language support.

TextKit 2 supports these main objects:

- `NSTextContentStorage`
- `NSTextContentManager`
- `NSTextLayoutManager`
- `NSTextContainer`
- `NSTextViewportLayoutController`
- `NSTextLayoutFragment`
- `NSTextLineFragment`

Source: [TextKit](https://developer.apple.com/documentation/appkit/textkit).

`NSTextViewportLayoutController` defines an active viewport. Apple describes the viewport as the visible area plus an over-scroll region. The controller provides `viewportBounds`, `viewportRange`, `layoutViewport()`, `relocateViewport(to:)`, and `adjustViewport(byVerticalOffset:)`.

Source: [NSTextViewportLayoutController](https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontroller).

The viewport delegate provides these exact hooks:

- `textViewportLayoutControllerWillLayout(_:)`
- `textViewportLayoutController(_:configureRenderingSurfaceFor:)`
- `textViewportLayoutControllerDidLayout(_:)`
- `viewportBounds(for:)`
- `textViewportLayoutController(_:cacheRenderingSurface:for:)`
- `textViewportLayoutController(_:retrieveCachedRenderingSurfaceFor:)`

Source: [NSTextViewportLayoutControllerDelegate](https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontrollerdelegate).

`NSTextLayoutManager` provides `ensureLayout(for:)`, `enumerateTextLayoutFragments(from:options:using:)`, `invalidateLayout(for:)`, `usageBoundsForTextContainer`, and `layoutQueue`.

`NSTextLayoutFragment` provides `layoutFragmentFrame`, `renderingSurfaceBounds`, `textLineFragments`, and `draw(at:in:)`. Apple says `renderingSurfaceBounds` is valid only after the fragment state passes `NSTextLayoutFragment.State.estimatedUsageBounds`.

Sources: [NSTextLayoutManager](https://developer.apple.com/documentation/appkit/nstextlayoutmanager), [NSTextLayoutFragment](https://developer.apple.com/documentation/appkit/nstextlayoutfragment), [renderingSurfaceBounds](https://developer.apple.com/documentation/appkit/nstextlayoutfragment/renderingsurfacebounds).

Recommended transcript pattern:

1. Keep one attributed document when messages do not need independent native views.
2. Use `NSTextContentStorage` for attributed string content.
3. Use the viewport controller to lay out visible fragments.
4. Use `NSTextLayoutFragment` as the drawing unit for custom surfaces.
5. Use text attachments or custom text elements only when message content needs embedded views.

This approach avoids one AppKit view per message. It is less direct when each message needs a bubble, context menu, independent accessibility element, or per-message drag target.

### Core Text and `CTFrame`

Core Text provides a lower-level path for custom text rendering. A `CTFramesetter` creates `CTFrame` objects from an attributed string and a path.

Use these exact APIs:

- `CTFramesetterCreateWithAttributedString`
- `CTFramesetterSuggestFrameSizeWithConstraints`
- `CTFramesetterCreateFrame`
- `CTFrameGetVisibleStringRange`
- `CTFrameGetLines`
- `CTFrameGetLineOrigins`
- `CTFrameDraw`
- `CTLineGetTypographicBounds`
- `CTLineGetBoundsWithOptions`

`CTFramesetterSuggestFrameSizeWithConstraints` returns the dimensions needed for a string range. A `CGFLOAT_MAX` constraint means that dimension is unconstrained. The optional `fitRange` reports the text that fits.

Source: [CTFramesetterSuggestFrameSizeWithConstraints](https://developer.apple.com/documentation/coretext/ctframesettersuggestframesizewithconstraints%28_%3A_%3A_%3A_%3A_%3A%29).

`CTFramesetterCreateFrame` creates an immutable frame for a `CGPath`. A zero string-range length lets the framesetter continue until it runs out of text or space.

Source: [CTFramesetterCreateFrame](https://developer.apple.com/documentation/coretext/ctframesettercreateframe%28_%3A_%3A_%3A_%3A%29).

`CTFrameGetLines` returns the line array. `CTFrameGetLineOrigins` returns line origins. `CTFrameDraw` draws the full frame into a `CGContext`.

Source: [CTFrame](https://developer.apple.com/documentation/coretext/ctframe).

`CTLineGetTypographicBounds` returns the line width and writes ascent, descent, and leading. `CTLineGetBoundsWithOptions` returns a `CGRect` with options such as `useOpticalBounds` and `excludeTypographicLeading`.

Sources: [CTLineGetTypographicBounds](https://developer.apple.com/documentation/coretext/ctlinegettypographicbounds%28_%3A_%3A_%3A_%3A%29), [CTLineGetBoundsWithOptions](https://developer.apple.com/documentation/coretext/ctlinegetboundswithoptions%28_%3A_%3A%29).

Recommended transcript pattern:

1. Build one attributed string per message or per visible page.
2. Call `CTFramesetterSuggestFrameSizeWithConstraints` with the transcript width.
3. Cache the returned height with the message content and width revision.
4. Create and draw a frame only for visible messages.
5. Implement selection, accessibility, links, and attachment handling at the custom view layer.

## Open-source macOS chat clients

### Textual

The official [Codeux-Software/Textual repository](https://github.com/Codeux-Software/Textual) is an open-source macOS IRC client.

Its member list uses an `NSTableView` reuse call and a custom row view:

- [`tableView:viewForTableColumn:row:` and `makeViewWithIdentifier:owner:`](https://github.com/Codeux-Software/Textual/blob/master/Sources/App/Classes/IRC/IRCChannel.m#L698-L715)

Its main chat transcript uses WebKit-backed rendering instead of `NSTableView`, `NSCollectionView`, TextKit, or Core Text:

- [`constructWebView`](https://github.com/Codeux-Software/Textual/blob/master/Sources/App/Classes/Views/Channel%20View/TVCLogView.m#L101-L112) selects a WebKit 1 or WebKit 2 backing view.
- [`loadHTMLString`](https://github.com/Codeux-Software/Textual/blob/master/Sources/App/Classes/Views/Channel%20View/TVCLogView.m#L225-L254) loads the HTML transcript.
- [`Render the result in WebKit`](https://github.com/Codeux-Software/Textual/blob/master/Sources/App/Classes/Views/Channel%20View/TVCLogController.m#L525-L526) appends rendered transcript content.

Finding: Textual is useful evidence for native table reuse around a chat view. Its main transcript is not evidence for a native AppKit transcript renderer.

### Adium

The official [adium/adium repository](https://github.com/adium/adium) describes Adium as an open-source macOS instant messaging client. Its main message view is the [WebKit Message View](https://github.com/adium/adium/tree/master/Plugins/WebKit%20Message%20View).

The message view creates an `ESWebView`:

- [`_initWebView`](https://github.com/adium/adium/blob/master/Plugins/WebKit%20Message%20View/AIWebKitMessageViewController.m#L315-L324)

It appends messages by evaluating JavaScript:

- [`_appendContent`](https://github.com/adium/adium/blob/master/Plugins/WebKit%20Message%20View/AIWebKitMessageViewController.m#L783-L790)

It also exposes the HTML chat source and replaces the `Chat` element:

- [`setChatContentSource:`](https://github.com/adium/adium/blob/master/Plugins/WebKit%20Message%20View/AIWebKitMessageViewController.m#L1692-L1708)

Adium’s separate transcript viewer uses `NSTextView` for the selected log content:

- [`textStorage` update](https://github.com/adium/adium/blob/master/Source/AILogViewerWindowController.m#L970-L978)
- [`NSTextView` print view](https://github.com/adium/adium/blob/master/Source/AILogViewerWindowController.m#L2512-L2528)

Adium also shows a cached height pattern for an `NSTableView`. `AIAccountListPreferences.m` uses `MINIMUM_ROW_HEIGHT 34`, stores heights in `requiredHeightDict`, and returns cached values from `tableView:heightOfRow:`:

- [height constant and cache](https://github.com/adium/adium/blob/master/Source/AIAccountListPreferences.m#L39-L42)
- [cached row height](https://github.com/adium/adium/blob/master/Source/AIAccountListPreferences.m#L877-L891)

Finding: Adium demonstrates WebKit for the main rich chat surface, plus `NSTextView` and cached table heights in supporting transcript UI. It does not provide a native `NSCollectionView` chat transcript example in the inspected source.

## Practical choice

For a bubble-style chat transcript, start with a view-based `NSTableView`. Use stable message identifiers and a height cache. This gives native selection, accessibility, keyboard behavior, and reusable row views.

Choose `NSCollectionView` when the transcript needs multiple sections or custom item layouts. Set `estimatedItemSize` and supply actual sizes after measurement.

Choose TextKit 2 for a continuous document with large text volume. Use the viewport controller to limit active layout work.

Choose Core Text only when custom drawing control is more important than built-in text interaction. Use `CTFramesetterSuggestFrameSizeWithConstraints` for precomputed heights.


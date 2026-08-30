# Apple native typography findings

Research date: 2026-08-28

Scope: official Apple Human Interface Guidelines, UIKit, SwiftUI, AppKit, and WWDC sources.

## Verified facts

- Apple defines a text style as a combination of font weight, point size, and leading for a text size: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple says text styles preserve hierarchy while text scales for system text-size and accessibility adjustments: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple identifies San Francisco as the system font for iOS, iPadOS, and macOS: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple identifies SF Pro as the system font for iOS, iPadOS, and macOS: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple says iOS and iPadOS apps can use New York, and Mac Catalyst apps can use New York: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple defines Dynamic Type as a system-level feature for iOS and iPadOS that lets people adjust visible text size: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple states that macOS does not support Dynamic Type: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple lists iOS and iPadOS standard Dynamic Type sizes as xSmall, Small, Medium, Large, xLarge, xxLarge, and xxxLarge: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple lists iOS and iPadOS larger accessibility sizes as AX1, AX2, AX3, AX4, and AX5: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple specifies iOS and iPadOS Large body text as Regular, 17 points, and 22 points leading: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple specifies iOS and iPadOS AX5 body text as Regular, 53 points, and 62 points leading: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple specifies macOS body text as Regular, 13 points, and 16 points line height: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple lists iOS and iPadOS default and minimum type sizes as 17 points and 11 points: [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/).
- Apple lists macOS default and minimum type sizes as 13 points and 10 points: [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/).
- Apple recommends supporting text enlargement of at least 200 percent: [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/).
- Apple says system fonts automatically support Dynamic Type where available and accessibility features such as Bold Text: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple says system fonts dynamically adjust tracking at every point size: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple specifies SF Pro tracking at 17 points as negative 4 in 1/1000 em and negative 0.07 points: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple specifies macOS tracking at 13 points as negative 6 in 1/1000 em and negative 0.08 points: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple recommends loose leading for wide columns or long passages and says to avoid tight leading for three or more lines: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple says `Font.Leading.standard` is the default line spacing, `loose` increases line spacing, and `tight` reduces line spacing: [Font.Leading](https://developer.apple.com/documentation/swiftui/font/leading).
- Apple says tight and loose leading change iOS and macOS line height by two points: [WWDC20 UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/).
- Apple defines leading as space between lines and says line height includes leading: [WWDC20 UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/).
- Apple says custom tracking should be size-specific and system tracking should be overridden only in exceptional cases: [WWDC20 UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/).
- Apple says `UIFont.preferredFont(forTextStyle:)` returns a system font scaled for the selected content size category: [UIFont](https://developer.apple.com/documentation/uikit/uifont).
- Apple defines UIKit text styles including `largeTitle`, `title1`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption1`, and `caption2`: [UIFont.TextStyle](https://developer.apple.com/documentation/uikit/uifont/textstyle).
- Apple says `UIFontMetrics` scales custom fonts to support Dynamic Type: [UIFontMetrics](https://developer.apple.com/documentation/uikit/uifontmetrics).
- Apple says `UIFontMetrics.scaledValue(for:)` scales arbitrary layout values using current Dynamic Type settings: [UIFontMetrics](https://developer.apple.com/documentation/uikit/uifontmetrics).
- Apple requires `adjustsFontForContentSizeCategory` to be true for a UIKit control to update its font when the content size category changes: [UIContentSizeCategoryAdjusting](https://developer.apple.com/documentation/uikit/uicontentsizecategoryadjusting/adjustsfontforcontentsizecategory).
- Apple says automatic UIKit font adjustment requires a font from `preferredFont(forTextStyle:)` or a `UIFontMetrics` scaling method: [UIContentSizeCategoryAdjusting](https://developer.apple.com/documentation/uikit/uicontentsizecategoryadjusting/adjustsfontforcontentsizecategory).
- Apple defines `UIContentSizeCategory.isAccessibilityCategory` to identify accessibility content size categories: [UIContentSizeCategory](https://developer.apple.com/documentation/uikit/uicontentsizecategory).
- Apple defines `UIContentSizeCategory.didChangeNotification` for changes to the preferred content size: [UIContentSizeCategory](https://developer.apple.com/documentation/uikit/uicontentsizecategory).
- Apple says UIKit list content `numberOfLines` equal to zero means no line limit: [UIListContentTextProperties.numberOfLines](https://developer.apple.com/documentation/uikit/uilistcontenttextproperties/numberoflines).
- Apple defines `UIView.readableContentGuide` as a layout guide for readable-width content: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- Apple says `readableContentGuide` never extends beyond layout margins: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- Apple says `readableContentGuide` is vertically centered inside layout margins: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- Apple says `readableContentGuide` width is equal to or less than the readable width for the current Dynamic Type size: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- Apple recommends `readableContentGuide` for a single column of text: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- Apple defines SwiftUI `Font` as an environment-dependent font resolved when used: [Font](https://developer.apple.com/documentation/swiftui/font).
- Apple defines SwiftUI `Font.TextStyle` values for extra-large titles, large title, title, title2, title3, headline, subheadline, body, callout, caption, caption2, and footnote: [Font.TextStyle](https://developer.apple.com/documentation/swiftui/font/textstyle).
- Apple says `Font.custom(_:size:)` scales relative to body by default, while `Font.custom(_:size:relativeTo:)` selects another text style: [Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text).
- Apple says `Font.custom(_:fixedSize:)` does not scale with Dynamic Type: [Font](https://developer.apple.com/documentation/swiftui/font).
- Apple defines SwiftUI `DynamicTypeSize` values from xSmall through xxxLarge and accessibility1 through accessibility5: [DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize).
- Apple defines `DynamicTypeSize.isAccessibilitySize` for accessibility-associated sizes: [DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize).
- Apple says SwiftUI `EnvironmentValues.dynamicTypeSize` changes when the user changes the Dynamic Type size: [EnvironmentValues.dynamicTypeSize](https://developer.apple.com/documentation/swiftui/environmentvalues/dynamictypesize).
- Apple says SwiftUI `EnvironmentValues.dynamicTypeSize` cannot be changed by users on macOS and does not affect text size there: [EnvironmentValues.dynamicTypeSize](https://developer.apple.com/documentation/swiftui/environmentvalues/dynamictypesize).
- Apple says SwiftUI `Text.tracking(_:)` adds spacing in points between character clusters and uses system defaults at zero: [Text.tracking(_:)](https://developer.apple.com/documentation/swiftui/text/tracking%28_%3A%29).
- Apple says SwiftUI `Text.kerning(_:)` changes character spacing and that tracking takes precedence when both modifiers are present: [Text.kerning(_:)](https://developer.apple.com/documentation/swiftui/text/kerning%28_%3A%29).
- Apple provides SwiftUI `lineSpacing(_:)`, `lineLimit(_:)`, and `allowsTightening(_:)` for text layout: [Text and symbol modifiers](https://developer.apple.com/documentation/swiftui/view-text-and-symbols).
- Apple provides SwiftUI `textSelection(_:)` to control text selection: [Text and symbol modifiers](https://developer.apple.com/documentation/swiftui/view-text-and-symbols).
- Apple provides SwiftUI `accessibilityHeading(_:)` with heading levels h1 through h6 and unspecified: [accessibilityHeading(_:)](https://developer.apple.com/documentation/swiftui/view/accessibilityheading%28_%3A%29).
- Apple says assistive technologies can use SwiftUI heading levels to improve navigation through multiple headings: [AccessibilityHeadingLevel](https://developer.apple.com/documentation/swiftui/accessibilityheadinglevel).
- Apple defines AppKit `NSFont.TextStyle` values for largeTitle, title1, title2, title3, headline, subheadline, body, callout, footnote, caption1, and caption2: [NSFont.TextStyle](https://developer.apple.com/documentation/appkit/nsfont/textstyle).
- Apple says `NSFont.preferredFont(forTextStyle:options:)` returns the font associated with an AppKit text style: [NSFont](https://developer.apple.com/documentation/appkit/nsfont).
- Apple says AppKit supports text styles but macOS does not support Dynamic Type: [WWDC20 UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/).
- Apple lists AppKit dynamic system font variants including `controlContentFont(ofSize:)`, `labelFont(ofSize:)`, `messageFont(ofSize:)`, `menuFont(ofSize:)`, `titleBarFont(ofSize:)`, and `userFont(ofSize:)`: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- Apple defines `NSFont.leading` as the leading value of an AppKit font: [NSFont.leading](https://developer.apple.com/documentation/appkit/nsfont/leading).
- Apple defines `NSParagraphStyle.lineSpacing` as the point distance between the bottom of one line fragment and the top of the next: [NSParagraphStyle.lineSpacing](https://developer.apple.com/documentation/appkit/nsparagraphstyle/linespacing).
- Apple defines `NSParagraphStyle.paragraphSpacing` as the distance between the bottom of one paragraph and the top of the next: [NSParagraphStyle](https://developer.apple.com/documentation/appkit/nsparagraphstyle).
- Apple defines `NSParagraphStyle.lineHeightMultiple` as a multiplier applied to natural line height before minimum and maximum constraints: [NSMutableParagraphStyle.lineHeightMultiple](https://developer.apple.com/documentation/appkit/nsmutableparagraphstyle/lineheightmultiple).
- Apple lists WCAG guidance of 4.5:1 contrast for text up to 17 points, 3:1 for 18-point text, and 3:1 for bold text: [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/).
- Apple says text that can grow should grow, apps should use available screen width, and text should not truncate as it grows: [WWDC19 Visual Design and Accessibility](https://developer.apple.com/videos/play/wwdc2019/244/).

## Source limits and interpretation

- The cited Apple sources define a readable width through `UIView.readableContentGuide` but do not provide one universal numeric maximum in points: [UIView.readableContentGuide](https://developer.apple.com/documentation/uikit/uiview/readablecontentguide).
- The cited Apple sources define paragraph and line-spacing APIs but do not prescribe Markdown-specific paragraph, list, code-block, or table metrics: [NSParagraphStyle](https://developer.apple.com/documentation/uikit/nsparagraphstyle).
- The cited Apple sources support a native transcript body mapped to the platform body text style, with headings mapped to title or headline styles: [UIFont.TextStyle](https://developer.apple.com/documentation/uikit/uifont/textstyle), [Font.TextStyle](https://developer.apple.com/documentation/swiftui/font/textstyle), [NSFont.TextStyle](https://developer.apple.com/documentation/appkit/nsfont/textstyle).
- The cited Apple sources support system-managed tracking and standard leading for transcript prose, with loose leading reserved for long passages when testing confirms improved readability: [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Font.Leading](https://developer.apple.com/documentation/swiftui/font/leading).
- The cited Apple sources support monospaced system fonts for code while leaving code-block padding and border metrics to the app: [NSFont](https://developer.apple.com/documentation/appkit/nsfont), [Font](https://developer.apple.com/documentation/swiftui/font).

import AppKit
import SwiftUI

extension NSScrollView {
    /// Turns the system's own scroll edge effect off on this surface.
    ///
    /// macOS 26 gives a scroll view that reaches into the window's titlebar
    /// safe area an `NSScrollPocket`. The plate and its blur are extra
    /// compositing on every scroll step. `allowedPocketEdges` is the lever
    /// this build has. There is no public one: `NSScrollEdgeEffectStyle`
    /// reaches the effect only through titlebar and split-view accessory
    /// controllers, and picks a style rather than turning the effect off,
    /// while SwiftUI's `scrollEdgeEffectHidden` does not cross a
    /// representable boundary into an AppKit scroll view. Guarded on the
    /// setter, so a build where the property has moved leaves the system
    /// drawing its own edge — a cosmetic regression rather than a broken
    /// window.
    ///
    /// Call this from the surface's initializer and again from
    /// `viewDidMoveToWindow`. The pocket is created for the titlebar the
    /// scroll view lands under, not once for the view.
    func suppressSystemScrollEdgeEffect() {
        guard responds(to: Self.allowedPocketEdgesSetter) else { return }
        setValue(0, forKey: Self.allowedPocketEdgesKey)
    }

    fileprivate static let allowedPocketEdgesKey = "allowedPocketEdges"
    fileprivate static let allowedPocketEdgesSetter =
        NSSelectorFromString("setAllowedPocketEdges:")

    /// AppKit's macOS 26 titlebar scroll pocket views under this scroll view.
    ///
    /// The measured names are `NSScrollPocket`, `PocketMask`, and
    /// `PocketBlur`. A suppressed surface reports none of them.
    var systemScrollPocketViews: [NSView] {
        Self.collectPocketViews(from: self)
    }

    fileprivate static func collectPocketViews(from view: NSView) -> [NSView] {
        var found: [NSView] = []
        let name = NSStringFromClass(type(of: view))
        if name.hasSuffix("NSScrollPocket")
            || name.hasSuffix("PocketMask")
            || name.hasSuffix("PocketBlur")
        {
            found.append(view)
        }
        for subview in view.subviews {
            found.append(contentsOf: collectPocketViews(from: subview))
        }
        return found
    }
}

/// A zero-hit AppKit host that finds a SwiftUI `ListCoreScrollView` and
/// applies `NSScrollView.suppressSystemScrollEdgeEffect`.
///
/// The sidebar list is SwiftUI's, so this host is the AppKit end of that
/// representable boundary. The transcript owns its `NSScrollView` and calls
/// the same setter directly.
struct ScrollEdgeEffectSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollEdgeEffectSuppressingView {
        ScrollEdgeEffectSuppressingView()
    }

    func updateNSView(_ nsView: ScrollEdgeEffectSuppressingView, context: Context) {
        nsView.suppressAttachedScrollViews()
    }
}

@MainActor
final class ScrollEdgeEffectSuppressingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: .zero)
        // Stay in the tree so a window change can re-assert the setter. Draw
        // nothing and refuse hits, so the host cannot change layout or steal
        // clicks from the list.
        isHidden = false
        alphaValue = 0
        suppressAttachedScrollViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressAttachedScrollViews()
        // SwiftUI may install `ListCoreScrollView` after this host lands in
        // the window. One later turn re-asserts once that sibling exists.
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.suppressAttachedScrollViews()
            }
        }
    }

    func suppressAttachedScrollViews() {
        for scrollView in attachedListScrollViews() {
            scrollView.suppressSystemScrollEdgeEffect()
        }
    }

    func attachedListScrollViews() -> [NSScrollView] {
        var root: NSView = self
        while let superview = root.superview {
            if superview is NSSplitView { break }
            root = superview
            if root === window?.contentView { break }
        }

        var found: [NSScrollView] = []
        func addListCore(in view: NSView) {
            if NSStringFromClass(type(of: view)).contains("ListCoreScrollView"),
               let scroll = view as? NSScrollView {
                found.append(scroll)
                return
            }
            for subview in view.subviews {
                addListCore(in: subview)
            }
        }
        addListCore(in: root)

        if found.isEmpty, let enclosing = enclosingScrollView {
            found.append(enclosing)
        }
        if found.isEmpty {
            func addScrollView(in view: NSView) {
                if let scroll = view as? NSScrollView {
                    found.append(scroll)
                    return
                }
                for subview in view.subviews {
                    addScrollView(in: subview)
                }
            }
            addScrollView(in: root)
        }
        return found
    }
}

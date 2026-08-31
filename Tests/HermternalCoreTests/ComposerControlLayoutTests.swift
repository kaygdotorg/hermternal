import HermternalCore
import Testing

@Test("composer density uses fixed breakpoints without prior state")
func densityBreakpoints() {
    #expect(ComposerControlLayout.density(availableWidth: 480, previous: nil) == .full)
    #expect(ComposerControlLayout.density(availableWidth: 479.99, previous: nil) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 360, previous: nil) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 359.99, previous: nil) == .minimal)
}

@Test("composer density hysteresis prevents breakpoint oscillation")
func densityHysteresis() {
    #expect(ComposerControlLayout.density(availableWidth: 456, previous: .full) == .full)
    #expect(ComposerControlLayout.density(availableWidth: 455.99, previous: .full) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 504, previous: .condensed) == .full)
    #expect(ComposerControlLayout.density(availableWidth: 503.99, previous: .condensed) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 336, previous: .condensed) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 335.99, previous: .condensed) == .minimal)
    #expect(ComposerControlLayout.density(availableWidth: 384, previous: .minimal) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 383.99, previous: .minimal) == .minimal)
}

/// A width that has room for the full row must reach it in one update.
///
/// A layout pass applies the composer its ideal width once — measured at
/// 196.5pt for a composer that then occupies 714 — so the model does see a
/// narrow width it never draws at. While `minimal` could only step up to
/// `condensed`, that single measurement cost a level the composer never got
/// back: an idle chat reports no further width, and the row stayed one level
/// below what it had room for until the window was resized.
@Test("composer density leaves minimal for the band the width supports")
func densityLeavesMinimalForTheWidestBandItFits() {
    #expect(ComposerControlLayout.density(availableWidth: 714, previous: .minimal) == .full)
    #expect(ComposerControlLayout.density(availableWidth: 504, previous: .minimal) == .full)
    // The upper dead band still holds: leaving one band takes the hysteresis.
    #expect(ComposerControlLayout.density(availableWidth: 503.99, previous: .minimal) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 384, previous: .minimal) == .condensed)
    #expect(ComposerControlLayout.density(availableWidth: 383.99, previous: .minimal) == .minimal)
}

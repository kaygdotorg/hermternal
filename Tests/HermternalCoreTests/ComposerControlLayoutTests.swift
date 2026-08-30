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

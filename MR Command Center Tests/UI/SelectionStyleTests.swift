import Foundation
import Testing
@testable import MR_Command_Center

/// The selected MR card must be obvious (#24): several cues, all strong enough to see.
struct SelectionStyleTests {
    @Test func selectedCardDiffersInEveryCue() {
        let selected = CardSelectionStyle.style(isSelected: true)
        let normal = CardSelectionStyle.style(isSelected: false)
        #expect(selected.borderWidth >= 2 * normal.borderWidth)
        #expect(selected.tintOpacity > 0 && normal.tintOpacity == 0)
        #expect(selected.accentBarWidth > normal.accentBarWidth)
        #expect(selected.showsMarker && !normal.showsMarker, "A shape cue, not just color")
        #expect(selected.shadowRadius > normal.shadowRadius)
    }

    @Test func selectingNeverShiftsTheContent() {
        #expect(CardSelectionStyle.selected.contentLeadingInset == CardSelectionStyle.unselected.contentLeadingInset)
        #expect(CardSelectionStyle.selected.contentLeadingInset >= CardSelectionStyle.selected.accentBarWidth + 8,
                "The widest bar fits inside the inset")
    }

    @Test func onStatesStayLighterThanSelection() {
        let on = CardSelectionStyle.highlighted
        #expect(on.borderWidth < CardSelectionStyle.selected.borderWidth)
        #expect(on.tintOpacity == 0 && !on.showsMarker)
    }

    @Test(arguments: Lane.allCases)
    func selectionColorStandsOutOnTheTintedCard(lane: Lane) {
        let surface = CardSelectionStyle.tintedSurface(Theme.Hex.lane(lane))
        let ratio = Contrast.ratio(Theme.Hex.selection(lane), surface)
        #expect(ratio >= 3, "\(lane) selection color is only \(ratio):1 against its tinted card")
    }

    @Test(arguments: Lane.allCases)
    func selectionColorStandsOutOnTheCanvas(lane: Lane) {
        let ratio = Contrast.ratio(Theme.Hex.selection(lane), Theme.Hex.canvas)
        #expect(ratio >= 3, "\(lane) selection color is only \(ratio):1 against the canvas")
    }

    @Test(arguments: Lane.allCases)
    func selectionColorStandsOutOnTheCard(lane: Lane) {
        let ratio = Contrast.ratio(Theme.Hex.selection(lane), Theme.Hex.surface)
        #expect(ratio >= 3, "\(lane) selection color is only \(ratio):1 against a white card")
    }

    @Test func faintLaneColorsFallBackToInk() {
        #expect(Contrast.ratio(Theme.Hex.inkTertiary, Theme.Hex.canvas) < 3, "Precondition: set aside's gray is faint")
        #expect(Theme.Hex.selection(.setAside) == Theme.Hex.inkSecondary)
        #expect(Theme.Hex.selection(.drafts) == Theme.Hex.inkSecondary, "Drafts gray sits just under 3:1")
        #expect(Theme.Hex.selection(.yourMove) == Theme.Hex.yourMove)
    }

    @Test func contrastMatchesKnownValues() {
        #expect(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Contrast.ratio(0xFFFFFF, 0xFFFFFF) - 1) < 0.01)
        #expect(Contrast.blend(0x000000, over: 0xFFFFFF, opacity: 0.5) == 0x808080)
    }
}

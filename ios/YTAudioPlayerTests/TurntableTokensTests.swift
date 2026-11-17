//
//  TurntableTokensTests.swift
//  YTAudioPlayerTests
//
//  Guards the Turntable deck's material palette and its generated
//  textures.
//
//  The texture assertions matter more than they look: a typo in an
//  asset name does NOT fail the build. `Image("Turntable/vinylGrooves")`
//  with the wrong casing simply renders nothing, so the platter would
//  ship as a flat black circle with no grooves at all.
//

import XCTest
import SwiftUI
@testable import PeacePlayer

final class TurntableTokensTests: XCTestCase {

    func testTextureNamesResolveToRealAssets() {
        for name in [TurntableTexture.vinylGrooves,
                     TurntableTexture.walnut,
                     TurntableTexture.brushedAluminium,
                     TurntableTexture.felt] {
            XCTAssertNotNil(UIImage(named: name),
                            "Missing asset: \(name)")
        }
    }

    func testHardwarePaletteIsDistinctFromCyberpunkSignals() {
        // The deck's warm surfaces must not collapse into the cyan/magenta
        // signal colours, or the hardware metaphor stops reading.
        let hardware = [TurntableTokens.walnut,
                        TurntableTokens.aluminium,
                        TurntableTokens.cream,
                        TurntableTokens.felt]
        let signals = [Theme.cyberCyan, Theme.cyberMagenta, Theme.cyberYellow]
        for h in hardware {
            for s in signals {
                XCTAssertNotEqual(h, s, "Hardware tone collided with signal colour")
            }
        }
    }
}

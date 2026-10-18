import Testing
import UIKit
@testable import Libretto

@Suite("Adapting document colours to dark mode")
struct AdaptiveColorTests {
    private func lightness(_ hex: String, isText: Bool) -> Double {
        let color = AdaptiveColor.platformColor(hex: hex, for: .dark, isText: isText)!
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Double(max(red, green, blue) + min(red, green, blue)) / 2
    }

    @Test("White paper and black ink flip")
    func lightDesignFlips() {
        #expect(lightness("FFFFFF", isText: false) < 0.05)
        #expect(lightness("000000", isText: true) > 0.95)
    }

    @Test("A dark fill with pale text stays as it was")
    func darkDesignStays() {
        #expect(abs(lightness("1E1E1E", isText: false) - 0.118) < 0.01)
        #expect(abs(lightness("D4D4D4", isText: true) - 0.831) < 0.01)
    }
}

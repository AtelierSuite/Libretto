#if !canImport(SwiftUI)
import Foundation

// The SwiftUI types the engine model uses (a colour and an appearance), for
// platforms without SwiftUI such as WebAssembly. They keep the same names and
// initialisers so model code compiles unchanged; a web front end reads the
// colour back out through `argbHex`.

public enum ColorScheme: Hashable, Sendable {
    case light
    case dark
}

public struct Color: Hashable, Sendable {
    public enum RGBColorSpace: Sendable {
        case sRGB
    }

    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}
#endif

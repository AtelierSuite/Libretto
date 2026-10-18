import Foundation

private final class EngineBundleMarker {}

extension Bundle {
    /// The engine's own bundle, which its strings are looked up in.
    static let engine = Bundle(for: EngineBundleMarker.self)
}

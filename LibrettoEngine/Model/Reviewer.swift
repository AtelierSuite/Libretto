import Foundation

/// Who is making changes and comments, as Word records them.
public enum Reviewer: Sendable {
    public static let nameKey = "authorName"

    public static var name: String {
        let stored = UserDefaults.standard.string(forKey: nameKey)?.trimmed ?? ""
        return stored.isEmpty ? String(localized: "Comment.DefaultAuthor", bundle: .engine) : stored
    }

    public static var initials: String {
        String(name.split(separator: " ").prefix(3).compactMap(\.first)).uppercased()
    }

    /// Now, as `w:date` spells it.
    public static var now: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

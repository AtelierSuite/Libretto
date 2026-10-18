import Foundation

/// Who is making changes and comments, as Word records them.
enum Reviewer {
    static let nameKey = "authorName"

    static var name: String {
        let stored = UserDefaults.standard.string(forKey: nameKey)?.trimmed ?? ""
        return stored.isEmpty ? String(localized: "Comment.DefaultAuthor") : stored
    }

    static var initials: String {
        String(name.split(separator: " ").prefix(3).compactMap(\.first)).uppercased()
    }

    /// Now, as `w:date` spells it.
    static var now: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

import Foundation

/// Computes the per-meeting folder path. Pure (no filesystem access).
struct ArchiveLayout {
    let root: URL
    init(root: URL) { self.root = root }

    static func slug(_ title: String?) -> String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Meeting" }
        let allowed = CharacterSet.alphanumerics
        let mapped = t.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "Meeting" : collapsed
    }

    func folder(date: Date, title: String?) -> URL {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        return root.appendingPathComponent("\(fmt.string(from: date))_\(Self.slug(title))")
    }
}

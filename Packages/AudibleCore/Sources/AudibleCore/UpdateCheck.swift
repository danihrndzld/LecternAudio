import Foundation

/// Help ▸ Check for Updates: compares the app version with GitHub's latest release tag.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/danihrndzld/Earmark/releases/latest")!

    /// "v1.2" vs "1.1.9" → true. Missing components count as 0; non-numeric suffixes ("1.2.0-beta") are ignored.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// `tag_name` of a GitHub release JSON body.
    public static func tag(fromRelease data: Data) -> String? {
        struct Release: Decodable { let tag_name: String }
        return try? JSONDecoder().decode(Release.self, from: data).tag_name
    }
}

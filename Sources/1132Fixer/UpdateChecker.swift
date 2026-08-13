import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let htmlURL: URL
    let releaseNotes: String?
}

enum UpdateChecker {
    // Keep this aligned with the repository link in ContentView.
    static let owner = "1132-Fixer"
    static let repo = "macos"
    static let errorDomain = "1132Fixer.UpdateChecker"
    private static let userAgent = "1132Fixer"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
        }
    }

    static func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: errorDomain,
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API returned HTTP \(http.statusCode)."]
            )
        }

        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // `/releases/latest` should already exclude drafts/prereleases, but keep a guardrail.
        if decoded.draft == true || decoded.prerelease == true {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Latest release is not a stable release."]
            )
        }

        let version = normalizeVersion(decoded.tagName)
        guard let htmlURL = URL(string: decoded.htmlURL),
              htmlURL.scheme == "https",
              htmlURL.host?.contains("github.com") == true else {
            throw NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid release URL."]
            )
        }

        return ReleaseInfo(version: version, htmlURL: htmlURL, releaseNotes: decoded.body)
    }

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    static func isUpdateAvailable(currentVersion: String, latestVersion: String) -> Bool {
        guard let current = SemVer.parse(currentVersion),
              let latest = SemVer.parse(latestVersion) else {
            return false
        }
        return latest > current
    }
}

struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func parse(_ s: String) -> SemVer? {
        // Accept "1.2.3" and tolerate suffixes like "1.2.3-beta" by stripping at first non [0-9.].
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.prefix { ch in
            (ch >= "0" && ch <= "9") || ch == "."
        }
        let parts = allowed.split(separator: ".")
        guard parts.count >= 1 else { return nil }

        func intPart(_ idx: Int) -> Int? {
            guard idx < parts.count else { return 0 }
            return Int(parts[idx])
        }

        guard let major = intPart(0),
              let minor = intPart(1),
              let patch = intPart(2) else {
            return nil
        }

        return SemVer(major: major, minor: minor, patch: patch)
    }
}

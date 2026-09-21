//  UpdateCheck.swift — the one request that says whether a newer release exists.
//
//  RFC-021. This is deliberately not an updater: the app is ad-hoc signed and
//  not notarised, so a downloaded build would still need the quarantine step
//  the release zip needs today. The useful, smaller promise is to tell the
//  user that a newer build exists and open its release page.
//
//  The request is made only when the Settings button is pressed. It is an
//  unauthenticated read of the public SpektraLab release endpoint; no
//  identifier, version or local state is sent.

import Foundation

/// One HTTP result, shaped for tests without requiring a URL loading system.
struct UpdateHTTPResponse: Sendable {
    let status: Int
    /// Header keys are lowercased by the live transport so lookups are
    /// case-insensitive, as HTTP requires.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

protocol UpdateTransport: Sendable {
    func latestRelease(from url: URL) async throws -> UpdateHTTPResponse
}

/// The shipping transport. Ephemeral, five seconds, no cache and no cookies.
struct URLSessionUpdateTransport: UpdateTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func latestRelease(from url: URL) async throws -> UpdateHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub asks API clients to identify themselves. This is the product
        // name, not a machine identifier and not the app version.
        request.setValue("SpektraLab", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        return UpdateHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

enum UpdateCheck {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/JamesQiu2005/SpektraLab/releases/latest")!

    enum Status: Equatable, Sendable {
        case idle
        case checking
        case updateAvailable(version: String, release: URL)
        case upToDate(version: String)
        case failed(reason: String)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private struct Version: Comparable {
        let fields: [Int]

        var display: String { fields.map(String.init).joined(separator: ".") }

        static func < (lhs: Version, rhs: Version) -> Bool {
            for i in 0..<max(lhs.fields.count, rhs.fields.count) {
                let left = i < lhs.fields.count ? lhs.fields[i] : 0
                let right = i < rhs.fields.count ? rhs.fields[i] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    /// Production entry point. The version comes from the bundle, never a
    /// literal in this file.
    static func check(currentVersion: String = Diagnostics.bundleInfo.version) async -> Status {
        await check(currentVersion: currentVersion, transport: URLSessionUpdateTransport())
    }

    /// Testable entry point. Every transport failure maps to `.failed`, never
    /// `.upToDate`: a check that learned nothing must not look successful.
    static func check(currentVersion: String, transport: any UpdateTransport) async -> Status {
        do {
            let response = try await transport.latestRelease(from: latestReleaseURL)
            guard (200..<300).contains(response.status) else {
                if response.status == 403, response.header("X-RateLimit-Remaining") == "0" {
                    return .failed(reason: "GitHub's unauthenticated rate limit was reached. Try again later.")
                }
                if response.status == 404 {
                    return .failed(reason: "No published SpektraLab release was found.")
                }
                return .failed(reason: "GitHub returned HTTP \(response.status).")
            }

            let release: GitHubRelease
            do {
                release = try JSONDecoder().decode(GitHubRelease.self, from: response.body)
            } catch {
                return .failed(reason: "GitHub's release reply could not be read.")
            }

            guard let latest = version(fromTag: release.tagName) else {
                return .failed(reason: "The latest release tag '\(release.tagName)' is not in the expected spektralab-vX.Y.Z form.")
            }
            guard let installed = version(fromString: currentVersion) else {
                return .failed(reason: "This build's version '\(currentVersion)' could not be read.")
            }

            return latest > installed
                ? .updateAvailable(version: latest.display, release: release.htmlURL)
                : .upToDate(version: latest.display)
        } catch is CancellationError {
            return .failed(reason: "The check was cancelled.")
        } catch {
            return .failed(reason: failureReason(error))
        }
    }

    private static func version(fromTag tag: String) -> Version? {
        let prefix = "spektralab-v"
        guard tag.hasPrefix(prefix) else { return nil }
        return version(fromString: String(tag.dropFirst(prefix.count)))
    }

    private static func version(fromString text: String) -> Version? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let fields = parts.compactMap { Int($0) }
        guard fields.count == parts.count else { return nil }
        return Version(fields: fields)
    }

    private static func failureReason(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut:
            return "GitHub did not answer within five seconds."
        case .notConnectedToInternet:
            return "This Mac appears to be offline."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "GitHub could not be reached."
        default:
            return urlError.localizedDescription
        }
    }
}

//  UpdateCheckTests.swift — RFC-021's failure paths, and the two success paths.

import XCTest

final class UpdateCheckTests: XCTestCase {
    private struct StubTransport: UpdateTransport {
        let response: UpdateHTTPResponse
        let error: URLError?

        init(status: Int, headers: [String: String] = [:], body: String,
             error: URLError? = nil) {
            response = UpdateHTTPResponse(status: status, headers: headers,
                                          body: Data(body.utf8))
            self.error = error
        }

        init(error: URLError) {
            response = UpdateHTTPResponse(status: 0, headers: [:], body: Data())
            self.error = error
        }

        func latestRelease(from url: URL) async throws -> UpdateHTTPResponse {
            if let error { throw error }
            return response
        }
    }

    private func release(_ tag: String, url: String = "https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-v1.0.4") -> String {
        """
        {"tag_name":"\(tag)","html_url":"\(url)"}
        """
    }

    func testTheCheckUsesTheSpektraLabReleaseEndpoint() {
        XCTAssertEqual(
            UpdateCheck.latestReleaseURL.absoluteString,
            "https://api.github.com/repos/JamesQiu2005/SpektraLab/releases/latest")
    }

    func testANewerPatchVersionIsComparedNumerically() async {
        let stub = StubTransport(status: 200, body: release("spektralab-v1.0.10"))
        let status = await UpdateCheck.check(currentVersion: "1.0.9", transport: stub)
        guard case .updateAvailable(let version, let url) = status else {
            return XCTFail("expected an update, got \(status)")
        }
        XCTAssertEqual(version, "1.0.10")
        XCTAssertEqual(url.absoluteString,
                       "https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-v1.0.4")
    }

    func testTheLatestReleaseIsReportedAsCurrent() async {
        let stub = StubTransport(status: 200, body: release("spektralab-v1.0.3"))
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        XCTAssertEqual(status, .upToDate(version: "1.0.3"))
    }

    func testARateLimitNeverLooksLikeUpToDate() async {
        let stub = StubTransport(status: 403, headers: ["x-ratelimit-remaining": "0"],
                                 body: #"{"message":"API rate limit exceeded"}"#)
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        guard case .failed(let reason) = status else {
            return XCTFail("a rate limit became \(status)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("rate limit"), reason)
    }

    func testAnUnparseableTagNeverLooksLikeUpToDate() async {
        let stub = StubTransport(status: 200, body: release("spektralab-vnext"))
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        guard case .failed(let reason) = status else {
            return XCTFail("an unparseable tag became \(status)")
        }
        XCTAssertTrue(reason.contains("spektralab-vnext"), reason)
    }

    func testNoReleaseNeverLooksLikeUpToDate() async {
        let stub = StubTransport(status: 404, body: #"{"message":"Not Found"}"#)
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        guard case .failed(let reason) = status else {
            return XCTFail("a missing release became \(status)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("no published"), reason)
    }

    func testANetworkFailureNeverLooksLikeUpToDate() async {
        let stub = StubTransport(error: URLError(.notConnectedToInternet))
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        guard case .failed(let reason) = status else {
            return XCTFail("an offline Mac became \(status)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("offline"), reason)
    }

    func testATimeoutNeverLooksLikeUpToDate() async {
        let stub = StubTransport(error: URLError(.timedOut))
        let status = await UpdateCheck.check(currentVersion: "1.0.3", transport: stub)
        guard case .failed(let reason) = status else {
            return XCTFail("a timeout became \(status)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("five seconds"), reason)
    }
}

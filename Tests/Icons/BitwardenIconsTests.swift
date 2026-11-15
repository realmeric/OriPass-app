import CryptoKit
import XCTest
@testable import OriPass

/// Answers every request from `answer`, so nothing here reaches a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var answer: (URLRequest) -> (Int, Data)? = { _ in nil }
    nonisolated(unsafe) static var seen: [URLRequest] = []
    /// Where every 3xx it answers with points.
    static let elsewhere = URL(string: "https://elsewhere.example.com/icon.png")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(request)
        guard let (status, body) = Self.answer(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if (300..<400).contains(status) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.elsewhere.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.elsewhere), redirectResponse: response)
            // And the answer ends there, as a server's does. A session that
            // takes the redirect has stopped listening to this one by now,
            // and one that refuses it would otherwise wait out its timeout.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class BitwardenIconsTests: XCTestCase {
    private func icons() -> BitwardenIcons {
        let configuration = BitwardenIcons.configuration
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        return BitwardenIcons(session: URLSession(configuration: configuration))
    }

    func testTheRequestIsAPathAndNothingElse() async {
        StubProtocol.answer = { _ in (200, tinyPNG()) }
        let fetcher = icons()
        XCTAssertEqual(fetcher.url(for: "www.isbank.com.tr").absoluteString,
                       "https://icons.bitwarden.net/www.isbank.com.tr/icon.png")
        let answer = await fetcher.fetch(host: "www.isbank.com.tr")
        XCTAssertEqual(answer, .image(tinyPNG()))

        let request = try? XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertNil(request?.httpBody)
        XCTAssertEqual(request?.allHTTPHeaderFields?["Cookie"], nil)
        XCTAssertEqual(request?.allHTTPHeaderFields?["Authorization"], nil)
        XCTAssertEqual(BitwardenIcons.configuration.httpShouldSetCookies, false)
        XCTAssertNil(BitwardenIcons.configuration.httpCookieStorage)
        XCTAssertNil(BitwardenIcons.configuration.urlCache)
    }

    func testTheGlobeTheServerGivesForAnUnknownSiteIsNoIcon() async {
        let globe = Fixture.bytes("icon-globe", "png")
        XCTAssertEqual(globe.count, 500)
        let digest = SHA256.hash(data: globe).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, BitwardenIcons.globeDigest)
        StubProtocol.answer = { _ in (200, globe) }
        let answer = await icons().fetch(host: "nothing.example.com")
        XCTAssertEqual(answer, .none)
    }

    func testWhatTheServerSaysIsSortedIntoAnIconNothingAndATryLater() async {
        let cases: [(Int, Data, IconAnswer)] = [
            (404, Data(), .none), (200, Data(), .none), (200, Data(count: BitwardenIcons.largest + 1), .none),
            (500, Data("oops".utf8), .failed), (429, Data(), .failed), (403, Data(), .failed),
        ]
        for (status, body, expected) in cases {
            StubProtocol.answer = { _ in (status, body) }
            let answer = await icons().fetch(host: "a.example.com")
            XCTAssertEqual(answer, expected, "\(status), \(body.count) bytes")
        }
        StubProtocol.answer = { _ in nil }
        let offline = await icons().fetch(host: "a.example.com")
        XCTAssertEqual(offline, .failed)
    }

    func testARedirectIsNotFollowedAndIsNoIcon() async {
        for status in [301, 302, 307, 308] {
            // Anywhere but the icon server would hand over a picture.
            StubProtocol.answer = { request in
                request.url?.host == "icons.bitwarden.net" ? (status, Data()) : (200, tinyPNG())
            }
            let answer = await icons().fetch(host: "moved.example.com")
            XCTAssertEqual(answer, .none, "\(status)")
            XCTAssertEqual(StubProtocol.seen.map { $0.url?.host }, ["icons.bitwarden.net"], "\(status)")
        }
    }

    func testAFetcherThatHasEndedAsksNobody() async {
        StubProtocol.answer = { _ in (200, tinyPNG()) }
        let fetcher = icons()
        let before = await fetcher.fetch(host: "a.example.com")
        XCTAssertEqual(before, .image(tinyPNG()))
        fetcher.end()
        fetcher.end()
        let after = await fetcher.fetch(host: "b.example.com")
        XCTAssertEqual(after, .failed)
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }
}

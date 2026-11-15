import XCTest
@testable import OriPass

final class URIMatchTests: XCTestCase {
    private let suffixes = PublicSuffix.standard

    private func page(_ written: String) throws -> Address {
        try XCTUnwrap(Address.page(written), written)
    }

    private func login(_ name: String, _ addresses: [(uri: String, match: Int64?)],
                       suffixes: PublicSuffix = .standard) throws -> Suggestions.Login {
        try XCTUnwrap(Suggestions.Login(Entry(try Item(json: .object([
            "id": .string("id-\(name)"), "type": .int(1), "name": .string(name),
            "login": .object([
                "username": .string("deniz"), "password": .string("hunter2-of-\(name)"),
                "uris": .array(addresses.map {
                    .object(["uri": .string($0.uri), "match": $0.match.map(JSONValue.int) ?? .null])
                }),
            ]),
        ]))), suffixes: suffixes))
    }

    // MARK: The list

    func testTheVendoredListIsInTheBundleAndReadsWhole() {
        XCTAssertEqual(suffixes.count, 10_336, "the count Vendor/psl/README.md gives")
    }

    func testASiteIsTheSuffixAndOneLabelMore() {
        XCTAssertEqual(suffixes.site(of: "www.isbank.com.tr"), "isbank.com.tr")
        XCTAssertEqual(suffixes.site(of: "isbank.com.tr"), "isbank.com.tr")
        XCTAssertEqual(suffixes.site(of: "accounts.google.com"), "google.com")
        XCTAssertEqual(suffixes.site(of: "a.b.example.co.uk"), "example.co.uk")
        XCTAssertNil(suffixes.site(of: "com.tr"), "a suffix is nobody's site")
        XCTAssertNil(suffixes.site(of: "localhost"))
        XCTAssertEqual(suffixes.site(of: "WWW.GitHub.com"), "github.com")
        XCTAssertEqual(suffixes.site(of: "deniz.github.io"), "deniz.github.io", "the private section is read too")
        XCTAssertEqual(suffixes.site(of: "printer.office.invalid"), "office.invalid",
                       "a name the list does not have is under its last label")
    }

    func testAStarTakesEveryNameUnderItAndABangGivesOneBack() {
        // *.ck and !www.ck are in the list as it came.
        XCTAssertEqual(suffixes.site(of: "shop.example.co.ck"), "example.co.ck")
        XCTAssertNil(suffixes.site(of: "co.ck"))
        XCTAssertEqual(suffixes.site(of: "www.ck"), "www.ck")
        XCTAssertEqual(suffixes.site(of: "a.www.ck"), "www.ck")

        let small = PublicSuffix(list: "// a comment\ncom\n*.platform.test\n!keep.platform.test\n\ntest trailing words\n")
        XCTAssertEqual(small.count, 4)
        XCTAssertEqual(small.site(of: "a.b.platform.test"), "a.b.platform.test")
        XCTAssertEqual(small.site(of: "x.a.b.platform.test"), "a.b.platform.test")
        XCTAssertEqual(small.site(of: "x.keep.platform.test"), "keep.platform.test")
    }

    /// A suffix the list spells in its own script, 公司.cn, is the same
    /// suffix as a browser writes it, xn--55qx5d.cn.
    func testASuffixInItsOwnScriptIsKnownInItsASCIIFormToo() throws {
        XCTAssertEqual(suffixes.site(of: "a.xn--55qx5d.cn"), "a.xn--55qx5d.cn")
        XCTAssertEqual(suffixes.site(of: "www.a.xn--55qx5d.cn"), "a.xn--55qx5d.cn")
        XCTAssertNil(suffixes.site(of: "xn--55qx5d.cn"), "a suffix is nobody's site in either spelling")
        XCTAssertEqual(suffixes.site(of: "a.公司.cn"), "a.公司.cn")
        XCTAssertEqual(suffixes.site(of: "www.a.公司.cn"), "a.公司.cn")
        XCTAssertNil(suffixes.site(of: "公司.cn"))
        // A top-level name of that kind, and a rule under a star.
        XCTAssertEqual(suffixes.site(of: "www.a.xn--mgberp4a5d4ar"), "a.xn--mgberp4a5d4ar")
        let small = PublicSuffix(list: "cn\n公司.cn\n*.müller.test\n!keep.müller.test\n")
        XCTAssertEqual(small.count, 4, "a rule is counted once, however many ways it is spelled")
        XCTAssertEqual(small.site(of: "x.a.b.xn--mller-kva.test"), "a.b.xn--mller-kva.test")
        XCTAssertEqual(small.site(of: "x.keep.xn--mller-kva.test"), "keep.xn--mller-kva.test")

        let rule = URIMatch.baseDomain
        for (own, other) in [("https://a.xn--55qx5d.cn", "https://b.xn--55qx5d.cn"),
                             ("https://a.公司.cn", "https://b.公司.cn"),
                             ("https://a.xn--55qx5d.cn", "https://b.公司.cn"),
                             ("https://a.公司.cn/giris", "https://b.xn--55qx5d.cn")] {
            XCTAssertFalse(rule.holds(Address(own), for: try page(other)), "\(own) and \(other) are two sites")
        }
        XCTAssertTrue(rule.holds(Address("https://www.a.xn--55qx5d.cn"), for: try page("https://giris.a.xn--55qx5d.cn")))
        XCTAssertTrue(rule.holds(Address("https://www.a.公司.cn"), for: try page("https://giris.a.xn--55qx5d.cn")),
                      "one site, written both ways")
        XCTAssertTrue(rule.holds(Address("https://www.a.xn--55qx5d.cn"), for: try page("https://giris.a.公司.cn")))
    }

    /// Without the list nothing is known about where a site ends, and the
    /// last two labels would make one site of every bank under com.tr. A
    /// site is then the whole host: less is suggested and nothing wrong.
    func testWithoutTheListASiteIsTheWholeHost() throws {
        let none = PublicSuffix.read(from: Bundle(for: URIMatchTests.self))
        XCTAssertEqual(none.count, 0, "the test bundle has no list in it")
        XCTAssertNil(none.site(of: "isbank.com.tr"))
        XCTAssertNil(none.site(of: "accounts.google.com"))
        XCTAssertEqual(Address("https://www.isbank.com.tr/giris", suffixes: none).site, "www.isbank.com.tr")

        func page(_ written: String) throws -> Address { try XCTUnwrap(Address.page(written, suffixes: none)) }
        func own(_ written: String) -> Address { Address(written, suffixes: none) }
        let rule = URIMatch.baseDomain
        XCTAssertFalse(rule.holds(own("https://isbank.com.tr"), for: try page("https://garanti.com.tr")))
        XCTAssertFalse(rule.holds(own("https://www.isbank.com.tr"), for: try page("https://www.garanti.com.tr")))
        XCTAssertFalse(rule.holds(own("https://google.com"), for: try page("https://accounts.google.com")),
                       "less is suggested")
        XCTAssertTrue(rule.holds(own("https://www.isbank.com.tr/giris"), for: try page("https://www.isbank.com.tr")))

        let banks = [try login("İş Bankası", [("https://isbank.com.tr", nil)], suffixes: none),
                     try login("Garanti", [("https://garanti.com.tr", nil)], suffixes: none)]
        let found = try XCTUnwrap(Suggestions.forPage(try page("https://garanti.com.tr/giris"), among: banks))
        XCTAssertEqual(found.entries.map(\.item.name), ["Garanti"])
        XCTAssertEqual(found.heading, "garanti.com.tr")
        let bank = FrontApp(pid: 1, bundleID: "tr.com.garanti.mobil", name: "Garanti")
        XCTAssertEqual(Suggestions.forApp(bank, among: banks, suffixes: none)?.entries.map(\.item.name), ["Garanti"],
                       "by its name, and never by a bundle id whose site nobody can tell")
    }

    // MARK: The six rules

    func testBaseDomainIsTheSameSiteWhateverTheHost() throws {
        let rule = URIMatch.baseDomain
        XCTAssertTrue(rule.holds(Address("https://google.com"), for: try page("https://accounts.google.com/signin")))
        XCTAssertTrue(rule.holds(Address("accounts.google.com/v3"), for: try page("http://mail.google.com")),
                      "an address kept as it was typed, without a scheme")
        XCTAssertFalse(rule.holds(Address("https://www.isbank.com.tr/giris"), for: try page("https://www.garanti.com.tr")),
                       "com.tr is a suffix and not a site")
        XCTAssertFalse(rule.holds(Address("https://isbank.com.tr"), for: try page("https://garanti.com.tr")))
        XCTAssertTrue(rule.holds(Address("https://www.isbank.com.tr/giris"), for: try page("https://internet.isbank.com.tr")))
        XCTAssertTrue(rule.holds(Address("http://192.168.1.1/admin"), for: try page("http://192.168.1.1")))
        XCTAssertFalse(rule.holds(Address("http://192.168.1.1"), for: try page("http://192.168.1.2")))
        XCTAssertFalse(rule.holds(Address("http://10.168.1.1"), for: try page("http://192.168.1.1")),
                       "an IP address has no suffix to share")
        XCTAssertTrue(rule.holds(Address("http://localhost:3000"), for: try page("http://localhost:8080")))
        XCTAssertFalse(rule.holds(Address(""), for: try page("https://google.com")))
    }

    func testHostIsTheSameHostAndTheSamePort() throws {
        let rule = URIMatch.host
        XCTAssertTrue(rule.holds(Address("https://accounts.google.com"), for: try page("https://accounts.google.com/signin")))
        XCTAssertFalse(rule.holds(Address("https://google.com"), for: try page("https://accounts.google.com/signin")))
        XCTAssertFalse(rule.holds(Address("https://accounts.google.com"), for: try page("https://google.com")))
        XCTAssertFalse(rule.holds(Address("http://localhost:3000"), for: try page("http://localhost:8080")))
        XCTAssertTrue(rule.holds(Address("http://localhost:3000/login"), for: try page("http://localhost:3000")))
        XCTAssertTrue(rule.holds(Address("https://example.com:443"), for: try page("https://example.com")),
                      "the scheme's own port is no port")
    }

    func testStartsWithIsThePagesAddressBeginningWithTheLogins() throws {
        let rule = URIMatch.startsWith
        XCTAssertTrue(rule.holds(Address("https://example.com/shop"), for: try page("https://example.com/shop/basket")))
        XCTAssertFalse(rule.holds(Address("https://example.com/shop"), for: try page("https://example.com/blog")))
        XCTAssertFalse(rule.holds(Address("https://example.com/shop"), for: try page("http://example.com/shop")))
    }

    func testExactIsTheTwoEqual() throws {
        let rule = URIMatch.exact
        XCTAssertTrue(rule.holds(Address("https://example.com/login"), for: try page("https://example.com/login")))
        XCTAssertFalse(rule.holds(Address("https://example.com/login"), for: try page("https://example.com/login?next=1")))
    }

    func testARegularExpressionIsReadAsOneWhateverTheCase() throws {
        let rule = URIMatch.regularExpression
        XCTAssertTrue(rule.holds(Address(#"^https://[a-z]+\.example\.com/"#), for: try page("https://Shop.Example.com/x")))
        XCTAssertFalse(rule.holds(Address(#"^https://[a-z]+\.example\.com/"#), for: try page("https://example.com/x")))
        XCTAssertFalse(rule.holds(Address("([unclosed"), for: try page("https://example.com/([unclosed")),
                       "a pattern that does not read is nobody's")
    }

    func testNeverIsNever() throws {
        XCTAssertFalse(URIMatch.never.holds(Address("https://example.com/login"), for: try page("https://example.com/login")))
    }

    func testAnAddressWithNoRuleHasBaseDomain() throws {
        XCTAssertEqual(LoginURI(uri: "https://google.com").rule, .baseDomain)
        XCTAssertTrue(LoginURI(uri: "https://google.com").belongs(to: try page("https://accounts.google.com")))
        XCTAssertFalse(LoginURI(uri: "https://google.com", match: .host).belongs(to: try page("https://accounts.google.com")))
        XCTAssertEqual(URIMatch.allCases.count, 6, "a seventh rule would be matched by nothing here")
    }

    /// What Bitwarden's phone app writes when it fills a native app. Its
    /// package name is no host: read as one, its tail is a site anybody
    /// can register.
    func testAnAppsIdentifierIsNoSiteAndIsSuggestedForNoPage() throws {
        for (written, tail) in [("androidapp://com.google.android.gm", "https://android.gm/"),
                                ("androidapp://com.valvesoftware.android.steam.community", "https://steam.community/login"),
                                ("iosapp://com.example.shop.app", "https://shop.app/"),
                                ("ftp://files.example.com", "https://example.com/")] {
            let own = Address(written)
            XCTAssertNil(own.host, written)
            XCTAssertNil(own.site, written)
            let page = try page(tail)
            XCTAssertFalse(URIMatch.baseDomain.holds(own, for: page), written)
            XCTAssertFalse(URIMatch.host.holds(own, for: page), written)
            let listed = [try login("Mail", [(written, nil)])]
            XCTAssertNil(Suggestions.forPage(page, among: listed), written)
            XCTAssertEqual(listed[0].sites, [], "and it names no site an app could be called after")
        }
        // The rules that read the text still read it.
        let app = Address("androidapp://com.example")
        XCTAssertTrue(URIMatch.exact.holds(app, for: Address("androidapp://com.example")))
        // An address with no scheme written, or with either of the web's, is as it was.
        XCTAssertEqual(Address("example.com/login").site, "example.com")
        XCTAssertEqual(Address("HTTP://www.example.com").site, "example.com")
    }

    func testOnlyAPageIsAPage() {
        for written in ["about:blank", "favorites://", "file:///Users/deniz/a.html", "brave://settings", "", "github.com"] {
            XCTAssertNil(Address.page(written), written)
        }
        XCTAssertEqual(Address.page("https://GitHub.com./login")?.site, "github.com")
    }

    // MARK: Which logins

    func testTheLoginsOfAPageAreThoseItsAddressesSayAreItsOwn() throws {
        let listed = [
            try login("Google", [("https://google.com", nil)]),
            try login("Google, this host only", [("https://google.com", 1)]),
            try login("Google accounts", [("https://accounts.google.com", 1)]),
            try login("İş Bankası", [("https://www.isbank.com.tr/giris", nil)]),
            try login("Garanti", [("https://www.garanti.com.tr", nil)]),
            try login("Never", [("https://accounts.google.com", 5)]),
            try login("Never, and one that is", [("https://accounts.google.com/x", 5), ("https://google.com", 0)]),
        ]
        let google = try XCTUnwrap(Suggestions.forPage(try page("https://accounts.google.com/signin"), among: listed))
        XCTAssertEqual(google.heading, "google.com")
        XCTAssertEqual(google.entries.map(\.item.name), ["Google accounts", "Google", "Never, and one that is"],
                       "the one on the very host leads, and an item set to never is not there")

        let bank = try XCTUnwrap(Suggestions.forPage(try page("https://www.garanti.com.tr/"), among: listed))
        XCTAssertEqual(bank.entries.map(\.item.name), ["Garanti"], "isbank.com.tr is another site")
        XCTAssertNil(Suggestions.forPage(try page("https://example.org"), among: listed))

        let used = try XCTUnwrap(Suggestions.forPage(try page("https://accounts.google.com"), among: listed,
                                                     usedLast: ["id-Google"]))
        XCTAssertEqual(used.entries.map(\.item.name), ["Google accounts", "Google", "Never, and one that is"],
                       "the host comes before the use")
        let later = try XCTUnwrap(Suggestions.forPage(try page("https://mail.google.com"), among: listed,
                                                      usedLast: ["id-Never, and one that is"]))
        XCTAssertEqual(later.entries.map(\.item.name), ["Never, and one that is", "Google"])
    }

    func testAnItemSetToNeverIsNeverSuggested() throws {
        let never = try login("Spotify", [("https://accounts.spotify.com", 5)])
        for written in ["https://accounts.spotify.com", "https://accounts.spotify.com/login", "https://spotify.com"] {
            XCTAssertNil(Suggestions.forPage(try page(written), among: [never]), written)
        }
        let app = FrontApp(pid: 1, bundleID: "com.spotify.client", name: "Spotify")
        XCTAssertNil(Suggestions.forApp(app, among: [never]), "not by its site and not by its title either")

        // What a failed assertion would print of either is a count and an id.
        let listed = try login("Slack", [("https://slack.com/signin", nil)])
        XCTAssertEqual(String(describing: listed), "Login(id-Slack)")
        let found = try XCTUnwrap(Suggestions.forPage(try page("https://slack.com"), among: [listed]))
        XCTAssertEqual(String(reflecting: found), "Suggestions(1)")
    }

    // MARK: Which app

    /// A bundle id names who made the app, and that is the app's own site
    /// only when the app is called after it.
    func testABundleIDIsTheSiteOnlyOfAnAppCalledAfterIt() throws {
        let listed = [
            try login("Spotify", [("https://accounts.spotify.com", nil)]),
            try login("Microsoft", [("https://account.microsoft.com", nil)]),
            try login("Things", [("https://culturedcode.com/things/cloud", nil)]),
            try login("Cultured Code forum", [("https://forum.culturedcode.com", nil)]),
        ]
        func names(_ id: String?, _ name: String) -> [String]? {
            Suggestions.forApp(FrontApp(pid: 1, bundleID: id, name: name), among: listed)?.entries.map(\.item.name)
        }
        XCTAssertEqual(names("com.spotify.client", "Spotify"), ["Spotify"])
        XCTAssertEqual(names("com.microsoft.teams2", "Microsoft Teams"), ["Microsoft"],
                       "the site's name is one of the app's words")
        XCTAssertEqual(names("com.culturedcode.ThingsMac", "Things"), ["Cultured Code forum", "Things"],
                       "a login on that site has the app's name for its title, so the site is the app's")
        XCTAssertNil(names("com.spotify.client", "Müzik"), "the vendor's name alone is not the app's")
        XCTAssertNil(names("com.microsoft.VSCode", "Code"))
        XCTAssertNil(names("com.culturedcode.ThingsMac", "Yapılacaklar"))
    }

    func testAnAppOfApplesOwnDoesNotOfferTheAppleAccount() throws {
        let listed = [try login("Apple Account", [("https://account.apple.com", nil)]),
                      try login("Mail", [("https://mail.example.org", nil)])]
        for (id, name) in [("com.apple.finder", "Finder"), ("com.apple.Terminal", "Terminal"),
                           ("com.apple.systempreferences", "Sistem Ayarları"), ("com.apple.Safari", "Safari"),
                           ("com.apple.dt.Xcode", "Xcode"), ("COM.APPLE.Music", "Apple Music")] {
            XCTAssertNil(Suggestions.forApp(FrontApp(pid: 1, bundleID: id, name: name), among: listed), id)
        }
        // Its name is still tried, as any app's is.
        let mail = FrontApp(pid: 1, bundleID: "com.apple.mail", name: "Mail")
        XCTAssertEqual(Suggestions.forApp(mail, among: listed)?.entries.map(\.item.name), ["Mail"])
    }

    /// A browser this app cannot ask, or one that would not say, is on a
    /// page nobody knows, and who made the browser says nothing about it.
    func testABrowserDoesNotOfferItsMakersLogin() throws {
        let listed = [
            try login("Google", [("https://accounts.google.com", nil)]),
            try login("Mozilla", [("https://accounts.mozilla.org", nil)]),
            try login("Brave", [("https://account.brave.com", nil)]),
            try login("Kagi", [("https://kagi.com/signin", nil)]),
            try login("Microsoft", [("https://account.microsoft.com", nil)]),
            try login("Vivaldi", [("https://login.vivaldi.com", nil)]),
        ]
        for (id, name) in [("com.google.Chrome", "Google Chrome"), ("com.google.Chrome.canary", "Google Chrome Canary"),
                           ("org.mozilla.firefox", "Firefox"), ("org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition"),
                           ("com.brave.Browser", "Brave Browser"), ("com.kagi.kagimacOS", "Orion"),
                           ("com.microsoft.edgemac", "Microsoft Edge"), ("com.vivaldi.Vivaldi", "Vivaldi"),
                           ("company.thebrowser.Browser", "Arc")] {
            let app = FrontApp(pid: 1, bundleID: id, name: name)
            XCTAssertTrue(app.isBrowser, id)
            XCTAssertNil(Suggestions.forApp(app, among: listed), id)
        }
        XCTAssertFalse(FrontApp(pid: 1, bundleID: "com.google.GoogleDrive", name: "Google Drive").isBrowser)
        XCTAssertFalse(FrontApp(pid: 1, bundleID: nil, name: "Firefox").isBrowser)
    }
}

import CryptoKit
import Foundation

/// What `OP_DEMO=1` unlocks with the password `demo`: about forty invented
/// items across every type, in three folders, with one of everything a
/// surface has to be able to draw.
///
/// Every secret in it comes from `canaries`, and `make canary` searches the
/// Mac for those strings after a lock (D6). They start `CANARY-` wherever the
/// field allows it; a card number and a one-time code's secret cannot, so
/// those are fixed values that mean nothing anywhere else. Every username is
/// at `kanarya.invalid`, so a leaked username is found too.
enum DemoVault {
    static let password = "demo"
    /// The demo's master password while the tour runs, so that the search
    /// can look for it: in the seal a finger opens, and everywhere else.
    static let tourPassword = "CANARY-MASTER-PASSWORD-h6Yt3nKq"

    // MARK: Canaries

    /// Weak by what they are and not by a word list that knows the marker:
    /// each is the marker said over, which is a repeat to `Guesswork`.
    static let weak = ["CANARYCANARY", "canarycanarycanary", "CanaryCanaryCanaryCanary"]
    static let shared = "CANARY-shared-R7u2Kp9wQx4LmZ"
    static let cardNumbers = ["4539578763621486", "5425233430109903", "374245455400126"]
    static let cardCode = "CANARY-CVV"
    static let totpSecrets = ["CANARYTOTPSECRETAAAA2345", "CANARYTOTPSECRETBBBB6723"]
    static let hiddenField = "CANARY-FIELD-pin-4471"
    static let old = ["CANARY-OLD-one", "CANARY-OLD-two", "CANARY-OLD-three"]
    static let privateKey = "CANARY-SSH-PRIVATE-KEY-b3BlbnNzaC1rZXktdjEAAAAA"
    /// GitHub's passkey is a real key under an invented scalar, thirty-two
    /// bytes of marker, since the tour signs with it. The vault holds it as
    /// Bitwarden writes it, PKCS#8 in URL-safe base64, and the search looks
    /// for that and for the scalar.
    static let passkeySeed = "CANARY-PASSKEY-SEED-29c6d1f4e08b"
    static let passkey = written(passkeySeed)
    /// The key a demo makes in place of a random one, so that the passkey
    /// the tour makes is searched for like the one the vault came with.
    static let newPasskeySeed = "CANARY-PASSKEY-MADE-71f0e3a2c95d"
    static let newPasskey = written(newPasskeySeed)
    static func newPasskeyKey() -> P256.Signing.PrivateKey {
        (try? P256.Signing.PrivateKey(rawRepresentation: Data(newPasskeySeed.utf8))) ?? P256.Signing.PrivateKey()
    }

    private static func written(_ seed: String) -> String {
        let key = (try? P256.Signing.PrivateKey(rawRepresentation: Data(seed.utf8)).derRepresentation) ?? Data()
        return key.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static let passkeyCredential = "7c0e8a52-3d14-4f6b-a9e7-5b21c6d0f893"
    static let numbers = ["CANARY-SSN-10000000146", "CANARY-PASSPORT-U00000000", "CANARY-LICENCE-000000"]
    static let note = "CANARY-NOTE"
    static let usernameDomain = "kanarya.invalid"

    /// A password nobody would call weak, different for every `n`.
    static func strong(_ n: Int) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+")
        var state = UInt64(n) &* 6364136223846793005 &+ 1442695040888963407
        var out = "CANARY-"
        for _ in 0..<20 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(alphabet[Int((state >> 33) % UInt64(alphabet.count))])
        }
        return out
    }

    /// Everything `make canary` looks for.
    static let canaries: [String] = weak + [shared] + cardNumbers + [cardCode] + totpSecrets
        + [hiddenField] + old + [privateKey, passkey, passkeySeed, newPasskey, newPasskeySeed] + numbers + [note, usernameDomain]
        + (1...loginCount).map(strong) + [session, tourPassword, signInPassword, signInCode, typed, unsaved, typedCode, pasted, made, pageTook, pageChanged]
        + [generatedStem, generatedWord, generatedWord.capitalized, generatedPIN, attached]
        + [agentSeed, agentKeyLine]

    /// What the tour types into the sign-in sheet's engine (`DemoTour`):
    /// a master password and a code, which the vault itself never holds.
    static let signInPassword = "CANARY-SIGNIN-PASSWORD-w8Rt2v"
    static let signInCode = "CANARY-SIGNIN-CODE-551902"

    /// What the tour hands the door as a page's password, and the one it
    /// changes that to, as a toast sends them.
    static let pageTook = "CANARY-PAGE-TOOK-q7Wd2mLx9Cv4"
    static let pageChanged = "CANARY-PAGE-CHANGED-k5Rn8tYb3Hf6"

    /// What the tour types into the editor's form: a password it saves, and
    /// one it leaves in the form for the lock to take.
    static let typed = "CANARY-TYPED-v4Lq8nXw2Rt6"
    static let unsaved = "CANARY-UNSAVED-m3Zk7pHs9Bd1"

    /// What the tour types into a card's form, and a line of the key it
    /// pastes into a key's.
    static let typedCode = "CANARY-TYPED-CVV-907"
    static let pasted = "CANARYPASTEDKEYq7Zt3Wm9Lx2Vb6Nc4Hd8Rf1Sg5Jk0"

    /// The password of the login the tour makes.
    static let made = "CANARY-MADE-t5Wq1nYc8Ks3"

    /// What is in the two files that go with the licence's note. They are in
    /// no item, and come only when the engine is asked for them.
    static let attached = "CANARY-ATTACHED-h6Jn3bQy9Te2"

    /// A licence as plain text, and an invoice that is one page of PDF with
    /// one line on it.
    static let attachments: [(id: String, name: String, body: Data)] = [
        (id(950), "lisans.txt", Data("""
            Yazılım lisansı

            Lisans sahibi: Deniz Yılmaz
            Anahtar: \(attached)
            Geçerlilik: süresiz, tek kullanıcı

            """.utf8)),
        (id(951), "fatura-2026.pdf", Data("""
            %PDF-1.4
            1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
            2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
            3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R
            /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >> endobj
            4 0 obj << /Length 64 >> stream
            BT /F1 14 Tf 72 760 Td (Fatura \(attached)) Tj ET
            endstream endobj
            trailer << /Root 1 0 R >>
            %%EOF

            """.utf8)),
    ]

    static var attachmentBodies: [String: Data] {
        Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0.body) })
    }

    /// What the demo's engine generates: the same password for the same
    /// recipe, so a shot is the same shot twice. A random one of any length
    /// starts with the stem, a memorable one with the word, and a PIN is the
    /// front of the twelve digits, which is the length the tour asks for,
    /// since four digits are in every log there is.
    static let generatedStem = "CANARYGN"
    static let generatedWord = "canarygn"
    static let generatedPIN = "907142835664"

    static func generated(_ recipe: PasswordRecipe) -> String {
        switch recipe {
        case .random(let length, let digits, let symbols):
            let letters = Array("xqLmVbTzRwKsHdPfGjNcYe")
            let marks = Array("!@#$%^&*")
            let rest = (0..<max(length - generatedStem.count, 0)).map { place -> Character in
                if digits, place % 4 == 1 { return Character(String(place * 7 % 10)) }
                if symbols, place % 5 == 3 { return marks[place % marks.count] }
                return letters[place * 5 % letters.count]
            }
            return String((generatedStem + String(rest)).prefix(length))
        case .memorable(let words, let separator, let capitals, let number):
            let list = [generatedWord, "limon", "deniz", "bulut", "ceviz", "orman", "sahil", "kiraz", "yaprak", "tuzluk"]
            var chosen = (0..<max(words, 1)).map { list[$0 % list.count] }.map { capitals ? $0.capitalized : $0 }
            if number { chosen[chosen.count - 1] += "7" }
            return chosen.joined(separator: separator)
        case .pin(let digits):
            return String(String(repeating: generatedPIN, count: 2).prefix(digits))
        }
    }

    /// A private key in OpenSSH's file format with nothing of a key in it:
    /// the public half is thirty-two counted bytes and the private half is
    /// one byte and `pasted`, which starts at the ninety-ninth byte and so,
    /// at forty-four columns, is the fourth line of the body by itself.
    static func keyFile(cipher: String = "none") -> String {
        func counted(_ bytes: Data) -> Data {
            Data(withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init)) + bytes
        }
        let publicHalf = counted(Data("ssh-ed25519".utf8)) + counted(Data(0..<32))
        let file = Data("openssh-key-v1\0".utf8) + counted(Data(cipher.utf8)) + counted(Data("none".utf8))
            + counted(Data()) + Data([0, 0, 0, 1]) + counted(publicHalf)
            + counted([0] + (Data(base64Encoded: pasted) ?? Data()))
        let body = file.base64EncodedString()
        let lines = stride(from: 0, to: body.count, by: 44).map { start in
            String(body.dropFirst(start).prefix(44))
        }
        return ([PastedKey.first] + lines + [PastedKey.last]).joined(separator: "\n") + "\n"
    }

    static let pastedKey = keyFile()

    /// The one key in the vault that signs (`SSHAgent`): thirty-two bytes
    /// that are a canary, as an Ed25519 key's seed, in OpenSSH's file. The
    /// tour's agent reads it, so the search looks for the seed and for a
    /// line of the file.
    static let agentSeed = "CANARY-SSH-AGENT-SEED-7f3a91c2d5"
    static let agentKeyName = "Git imza anahtarı"
    private static let agentKeyLines: [String] = {
        func counted(_ bytes: Data) -> Data {
            Data(withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init)) + bytes
        }
        let seed = Data(agentSeed.utf8)
        let point = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation) ?? Data()
        let kind = counted(Data("ssh-ed25519".utf8))
        let publicHalf = kind + counted(point)
        var privateHalf = Data(repeating: 7, count: 8) + kind + counted(point) + counted(seed + point) + counted(Data())
        let padding = (8 - privateHalf.count % 8) % 8
        privateHalf += Data((0..<padding).map { UInt8($0 + 1) })
        let file = Data("openssh-key-v1\0".utf8) + counted(Data("none".utf8)) + counted(Data("none".utf8))
            + counted(Data()) + Data([0, 0, 0, 1]) + counted(publicHalf) + counted(privateHalf)
        let body = file.base64EncodedString()
        return stride(from: 0, to: body.count, by: 70).map { String(body.dropFirst($0).prefix(70)) }
    }()
    /// A line from the private half, the seed among it.
    static let agentKeyLine = agentKeyLines[3]
    static let agentKey = ([PastedKey.first] + agentKeyLines + [PastedKey.last]).joined(separator: "\n") + "\n"

    /// The session the tour's stand-in `bw` answers an unlock with, which
    /// is the one in `Tests/Fixtures/unlock.json`. The app reads none, so
    /// the search finding this anywhere is the app having kept one.
    static let session = "CANARY-SESSION-q3J8mZ1x0vT5bN7cR2dF4gH6jK8lP0sA1uW3yE5iO7pQ9rT1vX3zB5nM7c=="

    // MARK: The vault

    @MainActor
    static func backend(now: Date = Date(), password: String = password) -> FakeBackend {
        let vault = objects(now: now)
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: password)
        backend.attachmentBodies = attachmentBodies
        return backend
    }

    static let folderNames = ["Dükkan", "İş", "Çalışma"]

    private static let loginCount = 30

    static func objects(now: Date = Date()) -> (items: [JSONValue], folders: [JSONValue]) {
        let folders = folderNames.enumerated().map { index, name in
            JSONValue.object(["object": .string("folder"), "id": .string(id(900 + index)),
                              "name": .string(name)])
        }
        let shop = id(900), work = id(901), study = id(902)
        var n = 0
        func next() -> Int { n += 1; return n }

        func login(_ name: String, _ address: String?, user: String?, password: String? = nil,
                   folder: String? = nil, _ more: [String: JSONValue] = [:],
                   login extra: [String: JSONValue] = [:]) -> JSONValue {
            let n = next()
            var login: [String: JSONValue] = [
                "fido2Credentials": .array([]),
                "uris": .array(address.map { [.object(["match": .null, "uri": .string($0)])] } ?? []),
                "username": JSONValue(user.map { "\($0)@\(usernameDomain)" }),
                "password": .string(password ?? strong(n)),
                "totp": .null, "passwordRevisionDate": .null,
            ]
            login.merge(extra) { $1 }
            return item(n, type: 1, name, folder: folder, more.merging(["login": .object(login)]) { $1 })
        }

        var items: [JSONValue] = [
            login("İş Bankası", "https://www.isbank.com.tr/giris", user: "deniz.yilmaz", folder: work,
                  ["favorite": .bool(true),
                   "notes": .string("Şube: Kadıköy. Limit için [yardım sayfası](https://example.com/yardim).\n\n\(note) müşteri temsilcisi dahili 4471."),
                   "fields": .array([
                       field("Müşteri no", "48213377", 0), field("PIN", hiddenField, 1),
                       field("Kurumsal", "true", 2),
                       .object(["name": .string("Kullanıcı"), "value": .null, "type": .int(3),
                                "linkedId": .int(100)]),
                   ]),
                   "passwordHistory": .array(old.enumerated().map { index, password in
                       .object(["lastUsedDate": .string(stamp(daysBefore: 60 * (index + 1))),
                                "password": .string(password)])
                   })],
                  login: ["totp": .string(totpSecrets[0]),
                          "uris": .array([
                              .object(["match": .null, "uri": .string("https://www.isbank.com.tr/giris")]),
                              .object(["match": .int(1), "uri": .string("https://internet.isbank.com.tr")]),
                              .object(["match": .int(5), "uri": .string("https://isbank.com.tr/kampanya")]),
                          ])]),
            login("GitHub", "https://github.com/login", user: "deniz", folder: study,
                  ["favorite": .bool(true), "reprompt": .int(1),
                   "notes": .string("## Kurtarma\n\n**Yedek kodlar** kasada, *basılı* kopya ~~çekmecede~~ dosyada.\n\n- telefon\n- yedek anahtar\n\n> Parola değişse de passkey kalır.")],
                  login: ["totp": .string("otpauth://totp/GitHub:deniz?secret=\(totpSecrets[1])&issuer=GitHub&period=30&digits=6"),
                          "fido2Credentials": .array([.object([
                              "credentialId": .string(passkeyCredential), "keyType": .string("public-key"),
                              "keyAlgorithm": .string("ECDSA"), "keyCurve": .string("P-256"),
                              "keyValue": .string(passkey), "rpId": .string("github.com"),
                              "userHandle": .string("ZGVuaXo"), "userName": .string("deniz"),
                              "counter": .string("0"), "rpName": .string("GitHub"),
                              "userDisplayName": .string("Deniz"), "discoverable": .string("true"),
                              "creationDate": .string(stamp(daysBefore: 230)),
                          ])])]),
            login("Şişecam Bayi Portalı", "https://bayi.sisecam.com.tr", user: "dukkan", folder: shop),
            login("Garanti BBVA", "https://www.garantibbva.com.tr", user: "deniz.yilmaz", folder: work),
            login("Digital Ocean", "https://cloud.digitalocean.com/login", user: "ops", folder: study),
            login("Spotify", "https://accounts.spotify.com", user: "deniz"),
            login("Google", "https://accounts.google.com", user: "deniz.yilmaz",
                  ["favorite": .bool(true)]),
            login("Apple Account", "https://account.apple.com", user: "deniz"),
            login("Trendyol", "https://www.trendyol.com/giris", user: "deniz", password: shared),
            login("Hepsiburada", "https://giris.hepsiburada.com", user: "deniz", password: shared),
            login("Eski forum", "http://forum.example.org/login", user: "denizy", password: weak[0]),
            login("Çiçeksepeti", "https://www.ciceksepeti.com", user: "deniz", password: weak[1]),
            login("Yemeksepeti", "https://www.yemeksepeti.com", user: "deniz", password: weak[2]),
            login("e-Devlet", "https://giris.turkiye.gov.tr", user: "10000000146"),
            login("Turkcell", "https://www.turkcell.com.tr", user: "5550000000"),
            login("İSKİ", "https://www.iski.istanbul", user: "abone"),
            login("Enerjisa", "https://www.enerjisa.com.tr", user: "abone"),
            login("Kadıköy Belediyesi", "https://www.kadikoy.bel.tr", user: "deniz"),
            login("Figma", "https://www.figma.com/login", user: "deniz", folder: study),
            login("Linear", "https://linear.app/login", user: "deniz", folder: study),
            login("Vercel", "https://vercel.com/login", user: "deniz", folder: study),
            login("Cloudflare", "https://dash.cloudflare.com/login", user: "ops", folder: study),
            login("Slack", "https://slack.com/signin", user: "deniz.yilmaz", folder: work),
            login("Notion", "https://www.notion.so/login", user: "deniz", folder: work),
            login("Paraşüt", "https://uygulama.parasut.com", user: "muhasebe", folder: shop),
            login("iyzico", "https://merchant.iyzipay.com", user: "dukkan", folder: shop),
            login("Yurtiçi Kargo", "https://www.yurticikargo.com", user: "dukkan", folder: shop),
            login("Ev Wi-Fi", nil, user: nil,
                  ["fields": .array([field("network name", "Kanarya-5G", 0),
                                     field("wireless security", "WPA3", 0)])]),
            login("Arşiv: üniversite", "https://obs.example.edu.tr", user: "20190001",
                  ["archivedDate": .string(stamp(daysBefore: 70))]),
            login("Kapanan hesap", "https://kapandi.example.com", user: "deniz",
                  ["deletedDate": .string(stamp(daysBefore: 6))]),
        ]
        assert(n == loginCount)

        items += [
            item(next(), type: 2, "Kombi servis notu", folder: nil,
                 ["notes": .string("Servis her ekim ayında gelir.\n\(note) abone numarası 7741."),
                  "secureNote": .object(["type": .int(0)])]),
            item(next(), type: 2, "Dükkan alarm kodu", folder: shop,
                 ["notes": .string("\(note) giriş 2580, çıkışta yıldız."),
                  "secureNote": .object(["type": .int(0)])]),
            item(next(), type: 2, "Yazılım lisansı", folder: study,
                 ["notes": .string("\(note) lisans anahtarı AAAA-BBBB-CCCC."),
                  "secureNote": .object(["type": .int(0)]),
                  "fields": .array([field("license key", hiddenField, 1)]),
                  "attachments": .array(attachments.map { file in
                      .object(["id": .string(file.id), "fileName": .string(file.name),
                               "size": .string(String(file.body.count)),
                               "sizeName": .string("\(file.body.count) Bytes"), "url": .null])
                  })]),
            item(next(), type: 2, "Boş not", folder: nil, ["secureNote": .object(["type": .int(0)])]),
            card(next(), "Bonus Kart", brand: "Mastercard", number: cardNumbers[1],
                 expires: Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: now) ?? now,
                 folder: nil, favorite: true),
            card(next(), "Maximum", brand: "Visa", number: cardNumbers[0],
                 expires: Calendar(identifier: .gregorian).date(byAdding: .year, value: 3, to: now) ?? now,
                 folder: work),
            card(next(), "Şirket Amex", brand: "Amex", number: cardNumbers[2],
                 expires: Calendar(identifier: .gregorian).date(byAdding: .year, value: 2, to: now) ?? now,
                 folder: shop),
            item(next(), type: 4, "Deniz Yılmaz", folder: nil, ["identity": .object([
                "title": .string("Mx"), "firstName": .string("Deniz"), "middleName": .null,
                "lastName": .string("Yılmaz"), "address1": .string("Moda Cd. 12"),
                "address2": .string("D: 4"), "address3": .null, "city": .string("İstanbul"),
                "state": .string("Kadıköy"), "postalCode": .string("34710"), "country": .string("TR"),
                "company": .string("Şişecam"), "email": .string("deniz@\(usernameDomain)"),
                "phone": .string("+90 555 000 00 00"), "ssn": .string(numbers[0]),
                "username": .string("deniz"), "passportNumber": .string(numbers[1]),
                "licenseNumber": .string(numbers[2]),
            ])]),
            item(next(), type: 4, "Dükkan (fatura)", folder: shop, ["identity": .object([
                "title": .null, "firstName": .string("Deniz"), "middleName": .null,
                "lastName": .string("Yılmaz"), "address1": .string("Bahariye Cd. 40"),
                "address2": .null, "address3": .null, "city": .string("İstanbul"),
                "state": .string("Kadıköy"), "postalCode": .string("34714"), "country": .string("TR"),
                "company": .string("Yılmaz Züccaciye"), "email": .string("dukkan@\(usernameDomain)"),
                "phone": .null, "ssn": .null, "username": .null, "passportNumber": .null,
                "licenseNumber": .null,
            ])]),
            item(next(), type: 5, "Sunucu anahtarı", folder: study, ["sshKey": .object([
                "privateKey": .string("-----BEGIN OPENSSH PRIVATE KEY-----\n\(privateKey)\n-----END OPENSSH PRIVATE KEY-----\n"),
                "publicKey": .string("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo deniz@mac"),
                "keyFingerprint": .string("SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem"),
            ])]),
            item(next(), type: 5, agentKeyName, folder: nil, ["sshKey": .object([
                "privateKey": .string(agentKey),
                "publicKey": .string("\((try? PastedKey(pasted: agentKey).publicKey) ?? "") deniz@mac"),
                "keyFingerprint": .string((try? PastedKey(pasted: agentKey).fingerprint) ?? ""),
            ])]),
            item(next(), type: 9, "Ehliyet", folder: nil, ["driversLicense": .object([
                "firstName": .string("Deniz"), "lastName": .string("Yılmaz"),
                "licenseNumber": .string(numbers[2]), "issuingCountry": .string("TR"),
                "expirationDate": .string("2031-01-01"),
            ])]),
        ]
        return (items, folders)
    }

    // MARK: -

    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)  // late September 2026

    private static func id(_ n: Int) -> String {
        String(format: "0de40000-0000-4000-8000-%012d", n)
    }

    private static func stamp(daysBefore days: Int) -> String {
        VaultDate.string(epoch.addingTimeInterval(-Double(days) * 86_400))
    }

    private static func field(_ name: String, _ value: String, _ type: Int64) -> JSONValue {
        .object(["name": .string(name), "value": .string(value), "type": .int(type), "linkedId": .null])
    }

    private static func item(_ n: Int, type: Int64, _ name: String, folder: String?,
                             _ more: [String: JSONValue]) -> JSONValue {
        let common: [String: JSONValue] = [
            "object": .string("item"), "id": .string(id(n)), "organizationId": .null,
            "folderId": JSONValue(folder), "type": .int(type), "reprompt": .int(0),
            "name": .string(name), "notes": .null, "favorite": .bool(false),
            "collectionIds": .array([]), "passwordHistory": .null,
            // Spread over a year and a half, so a list sorted by date has
            // more than one month to head. Every item was made before it was
            // last changed: the newest of them 313 days back, and no change
            // more than 299.
            "creationDate": .string(stamp(daysBefore: 300 + n * 13)),
            "revisionDate": .string(stamp(daysBefore: (n * 37) % 300)),
            "deletedDate": .null, "archivedDate": .null,
        ]
        return .object(common.merging(more) { $1 })
    }

    private static func card(_ n: Int, _ name: String, brand: String, number: String, expires: Date,
                             folder: String?, favorite: Bool = false) -> JSONValue {
        let parts = Calendar(identifier: .gregorian).dateComponents([.month, .year], from: expires)
        return item(n, type: 3, name, folder: folder, [
            "favorite": .bool(favorite),
            "card": .object([
                "cardholderName": .string("Deniz Yılmaz"), "brand": .string(brand),
                "number": .string(number), "expMonth": .string(String(parts.month ?? 1)),
                "expYear": .string(String(parts.year ?? 2027)), "code": .string(cardCode),
            ]),
        ])
    }
}

import Foundation

/// The Public Suffix List, and the one question it is kept for: which part
/// of a host is the site. `com.tr` is a suffix, so `isbank.com.tr` and
/// `garanti.com.tr` are two sites, which keeping "the last two labels"
/// would call one.
///
/// Both sections of the list are read, the registries' and the private one,
/// as Bitwarden's clients do: under `github.io` every name is its own site.
/// A rule the list spells in its own script, `公司.cn`, is kept in its
/// `xn--` form as well, so a host is known however it is written.
///
/// With no rules at all, which is the list missing from the bundle, no host
/// has a site: `Address` then takes the whole host for one, and nothing is
/// guessed from the last two labels.
struct PublicSuffix {
    private var plain: Set<String> = []
    /// What stands after the `*.` of a rule that takes every name under it.
    private var wild: Set<String> = []
    /// The names a `*.` rule does not take, written with a `!`.
    private var kept: Set<String> = []

    /// The rules as the list has them, each counted once.
    let count: Int

    init(list: String) {
        var count = 0
        for line in list.split(whereSeparator: \.isNewline) {
            // A rule ends at the first space, and a comment starts with two
            // strokes.
            guard let rule = line.split(whereSeparator: \.isWhitespace).first, !rule.hasPrefix("//") else { continue }
            let (isNew, spellings): (Bool, [String])
            if rule.hasPrefix("!") {
                spellings = Self.spellings(of: rule.dropFirst())
                isNew = kept.insert(spellings[0]).inserted
                kept.formUnion(spellings)
            } else if rule.hasPrefix("*.") {
                spellings = Self.spellings(of: rule.dropFirst(2))
                isNew = wild.insert(spellings[0]).inserted
                wild.formUnion(spellings)
            } else {
                spellings = Self.spellings(of: rule)
                isNew = plain.insert(spellings[0]).inserted
                plain.formUnion(spellings)
            }
            if isNew { count += 1 }
        }
        self.count = count
    }

    /// A name as the list writes it and, when that is not ASCII, as IDNA
    /// writes it too. `URLComponents.encodedHost` is Foundation's IDNA: on
    /// macOS 27 it gives `xn--55qx5d.cn` for `公司.cn`.
    private static func spellings(of name: Substring) -> [String] {
        let written = name.lowercased()
        guard !written.utf8.allSatisfy({ $0 < 0x80 }),
              let ascii = URLComponents(string: "https://" + written)?.encodedHost?.lowercased(), ascii != written
        else { return [written] }
        return [written, ascii]
    }

    /// The list in the bundle (`Vendor/psl`), read once, by whoever asks
    /// first. The delegate asks at launch and off the main thread, so that
    /// the hot key never waits for it.
    static let standard = read(from: .main)

    /// A bundle without the list gives one with no rules, which says so in
    /// the log and names no site.
    static func read(from bundle: Bundle) -> PublicSuffix {
        guard let file = bundle.url(forResource: "public_suffix_list", withExtension: "dat"),
              let list = try? String(contentsOf: file, encoding: .utf8)
        else {
            Log.app.error("the public suffix list is not in the bundle")
            return PublicSuffix(list: "")
        }
        return PublicSuffix(list: list)
    }

    /// The site a host belongs to: the suffix and one label more. Nil for a
    /// host that is itself a suffix, or has one label, and for every host
    /// when there are no rules to read it by.
    func site(of host: String) -> String? {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard count > 0, labels.count > 1, !labels.contains(where: \.isEmpty) else { return nil }
        func name(from place: Int) -> String { labels[place...].joined(separator: ".") }
        // The longest rule wins, so the search starts from the whole host.
        // A name no rule has is under its last label.
        var suffix = labels.count - 1
        for place in labels.indices {
            let here = name(from: place)
            if kept.contains(here) { return here }
            if plain.contains(here) || (place + 1 < labels.count && wild.contains(name(from: place + 1))) {
                suffix = place
                break
            }
        }
        return suffix > 0 ? name(from: suffix - 1) : nil
    }
}

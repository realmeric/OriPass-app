import SwiftUI

/// Where the app opens once the vault is: favourites and the last used
/// first, then each kind of item, each folder and the trash, with search
/// over all of it and a pull to sync.
struct VaultView: View {
    let model: AppModel
    let account: Account

    @State private var copying = Copying()
    @State private var query = ""
    @State private var tokens: [Item.Kind] = []
    @State private var settings = false
    @State private var generating = false
    @State private var making: Item.Kind?
    @FocusState private var searching: Bool

    enum Place: Hashable {
        case watch(String)
        case kind(Item.Kind)
        case folder(String)
        case trash
        case item(String)
    }

    private var live: [Item] { model.items.filter { !$0.deleted && !$0.archived } }
    private static let kinds: [Item.Kind] = [.login, .note, .card, .identity, .sshKey]

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && tokens.isEmpty { home } else { results }
            }
            .navigationTitle("OriPass")
            .searchable(text: $query, tokens: $tokens, prompt: Text("Search")) { kind in
                Label(kind.plural, systemImage: kind.symbol)
            }
            .searchFocused($searching)
            .onChange(of: QuickActions.shared.pending, initial: true) { _, action in
                if action == .search {
                    searching = true
                    QuickActions.shared.pending = nil
                }
            }
            .searchSuggestions {
                if query.isEmpty && tokens.isEmpty {
                    ForEach(Self.kinds, id: \.self) { kind in
                        Label(kind.plural, systemImage: kind.symbol).searchCompletion(kind)
                    }
                }
            }
            .refreshable { await model.sync(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock") { model.lockNow() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Generator", systemImage: "wand.and.stars") { generating = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("New Item", systemImage: "plus") {
                        Button("New Login", systemImage: "key") { making = .login }
                        Button("New Note", systemImage: "note.text") { making = .note }
                        Button("New Card", systemImage: "creditcard") { making = .card }
                        Button("New Identity", systemImage: "person.text.rectangle") { making = .identity }
                        Button("New SSH Key", systemImage: "terminal") { making = .sshKey }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
            }
            .navigationDestination(for: Place.self) { place in
                switch place {
                case .watch(let list):
                    let ids = Set(watchList(list)?.ids ?? [])
                    ItemsView(title: watchList(list)?.title ?? "", items: live.filter { ids.contains($0.id) }, rows: rows)
                case .kind(let kind): ItemsView(title: kind.plural, items: live.filter { $0.kind == kind }, rows: rows)
                case .folder(let id):
                    ItemsView(title: model.vault?.folders().first { $0.id == id }?.name ?? "",
                              items: live.filter { $0.folderId == id }, rows: rows)
                case .trash: ItemsView(title: String(localized: "Recently Deleted"),
                                       items: model.items.filter(\.deleted), rows: rows)
                case .item(let id):
                    if let item = model.items.first(where: { $0.id == id }) {
                        ItemView(item: item, server: model.choices.siteIcons ? account.server : nil, copying: copying, model: model)
                    }
                }
            }
            .sheet(isPresented: $settings) { SettingsView(model: model, account: account) }
            .sheet(isPresented: $generating) { GeneratorView(copying: copying) }
            .sheet(item: $making) { kind in
                EditItemView(item: nil, kind: kind, copying: copying, usernames: Usernames.ranked(model.items)) {
                    try await model.save($0, editing: nil)
                }
            }
        }
        .modifier(CopiedNotice(copying: copying))
    }

    @ViewBuilder private var home: some View {
        if !model.autoFillOn {
            Section {
                Button("Turn On AutoFill", systemImage: "key.viewfinder") { Task { await model.turnOnAutoFill() } }
            }
        }
        let favourites = live.filter(\.favorite).sorted(by: Self.byName)
        if !favourites.isEmpty {
            Section("Favorites") { rows(favourites) }
        }
        let recent = Recents.read().compactMap { id in live.first { $0.id == id } }.prefix(5)
        if !recent.isEmpty {
            Section("Recently Used") { rows(Array(recent)) }
        }
        if let watch = model.watch, !watch.isEmpty {
            Section("Password Health") {
                ForEach(["reused", "weak", "unsecured"], id: \.self) { list in
                    if let found = watchList(list), !found.ids.isEmpty {
                        NavigationLink(value: Place.watch(list)) {
                            Label(found.title, systemImage: found.symbol).badge(found.ids.count)
                        }
                    }
                }
            }
        }
        Section("Categories") {
            ForEach(Self.kinds, id: \.self) { kind in
                let count = live.filter { $0.kind == kind }.count
                if count > 0 {
                    NavigationLink(value: Place.kind(kind)) {
                        Label(kind.plural, systemImage: kind.symbol).badge(count)
                    }
                }
            }
        }
        let folders = model.vault?.folders() ?? []
        if !folders.isEmpty {
            Section("Folders") {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink(value: Place.folder(folder.id)) {
                        Label(folder.name, systemImage: "folder").badge(live.filter { $0.folderId == folder.id }.count)
                    }
                }
            }
        }
        let deleted = model.items.filter(\.deleted).count
        if deleted > 0 {
            Section {
                NavigationLink(value: Place.trash) {
                    Label("Recently Deleted", systemImage: "trash").badge(deleted)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let found = live.filter { item in
            (tokens.isEmpty || tokens.contains(item.kind)) && words.allSatisfy { word in
                item.searchText.contains(word)
            }
        }.sorted(by: Self.byName)
        if found.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            rows(found)
        }
    }

    private func rows(_ items: [Item]) -> some View {
        ForEach(items) { item in
            NavigationLink(value: Place.item(item.id)) {
                ItemRow(item: item, server: model.choices.siteIcons ? account.server : nil)
            }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if let password = item.login?.password {
                        Button("Copy Password", systemImage: "key") {
                            copying.copy(password, String(localized: "Password copied"), of: item)
                        }
                        .tint(.blue)
                    }
                    if let code = item.code {
                        Button("Copy Code", systemImage: "clock") { copying.copy(code, String(localized: "Code copied"), of: item) }
                            .tint(.orange)
                    }
                }
                .contextMenu { ItemMenu(item: item, copying: copying) }
        }
    }

    private func watchList(_ list: String) -> (title: String, symbol: String, ids: [String])? {
        guard let watch = model.watch else { return nil }
        switch list {
        case "reused": return (String(localized: "Reused Passwords"), "arrow.2.squarepath", watch.reused)
        case "weak": return (String(localized: "Weak Passwords"), "exclamationmark.shield", watch.weak)
        case "unsecured": return (String(localized: "Unsecured Websites"), "lock.open.trianglebadge.exclamationmark", watch.unsecured)
        default: return nil
        }
    }

    static func byName(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// One list of items, by name.
struct ItemsView<Rows: View>: View {
    let title: String
    let items: [Item]
    let rows: ([Item]) -> Rows

    var body: some View {
        List { rows(items.sorted(by: VaultView.byName)) }
            .navigationTitle(title)
            .overlay {
                if items.isEmpty { ContentUnavailableView(title, systemImage: "tray") }
            }
    }
}

/// What holding a row offers: each value copied, and the site opened.
struct ItemMenu: View {
    let item: Item
    let copying: Copying
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let username = item.login?.username {
            Button("Copy Username", systemImage: "person") { copying.copy(username, String(localized: "Username copied"), of: item) }
        }
        if let password = item.login?.password {
            Button("Copy Password", systemImage: "key") { copying.copy(password, String(localized: "Password copied"), of: item) }
        }
        if let code = item.code {
            Button("Copy Code", systemImage: "clock") { copying.copy(code, String(localized: "Code copied"), of: item) }
        }
        if let number = item.value("number") {
            Button("Copy Number", systemImage: "creditcard") { copying.copy(number, String(localized: "Number copied"), of: item) }
        }
        if let site = item.website {
            Divider()
            Button("Open Website", systemImage: "safari") {
                Recents.used(item.id)
                openURL(site)
            }
        }
    }
}

extension Item {
    /// The code a login's secret makes now.
    var code: String? { login?.totp.flatMap(Totp.init)?.code(at: .now) }

    /// The first address that a browser can open.
    var website: URL? {
        for uri in login?.uris ?? [] {
            let written = uri.uri.contains("://") ? uri.uri : "https://" + uri.uri
            if let url = URL(string: written), ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        }
        return nil
    }

    var searchText: String {
        ([name, login?.username ?? ""] + (login?.uris.map(\.uri) ?? []) + fields.compactMap(\.name)).joined(separator: " ").lowercased()
    }
}

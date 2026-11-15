import SwiftUI

/// The details as a form (`docs/look.md`, "Editing"). Nothing moves: the
/// strip, the icon, the title, the outlined group, the addresses, the custom
/// fields and the notes are where the details have them, and each has
/// become something to type into. Save and Cancel stand where Edit and the
/// ellipsis stood, and the vault's name is still a menu, which now changes
/// the form and sends nothing.
struct EditorView: View {
    @ObservedObject var panes: Panes
    @ObservedObject var editor: Editor
    /// The row with the caret, which wears the ring the arrows give a row
    /// of the details.
    @FocusState private var focus: String?

    private static let titleRow = "title"
    private static let usernameRow = "username"
    private static let notesRow = "notes"
    private static let yearRow = "year"
    private static let none = "None"

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.loose) {
                    if let notice = editor.notice { NoticeBanner(words: notice) }
                    header
                    switch editor.original.payload {
                    case .login:
                        Outlined { login }
                        websites
                    case .card:
                        Outlined { card }
                    case .identity:
                        Outlined { identity }
                    case .sshKey:
                        key
                    case .secureNote, .unknown:
                        EmptyView()
                    }
                    fields
                    notes
                    asking
                }
                .padding(.horizontal, Metrics.wide)
                .padding(.top, Metrics.wide)
                .padding(.bottom, Metrics.apart)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlayPreferenceValue(EditorMenuAnchor.self) { buttons in
            EditorMenuLayer(panes: panes, editor: editor, anchors: buttons)
        }
        .overlayPreferenceValue(GeneratorAnchor.self) { wand in
            FieldGeneratorLayer(panes: panes, anchor: wand)
        }
        .onAppear { focus = Self.titleRow }
    }

    // MARK: The strip

    /// The vault the form says, which is the item's own until he chooses
    /// another.
    private var vault: Vault {
        if editor.form.folderID == editor.original.folderID { return panes.store.vault(of: editor.original) }
        let place = editor.form.folderID.map(Vault.Place.folder) ?? .personal
        return panes.vaults.first { $0.id == place } ?? .personal
    }

    private var bar: some View {
        HStack(spacing: Metrics.gap) {
            Button { editor.toggle(.vault) } label: {
                HStack(spacing: Metrics.close) {
                    VaultDot(name: vault.name)
                    Text(vault.name).lineLimit(1)
                    Glyph.chevronDown.image
                        .font(Fonts.disclosure)
                        .foregroundStyle(Palette.secondText)
                }
                .padding(.horizontal, Metrics.close)
                .frame(minHeight: Metrics.buttonHeight)
                .background(lit(editor.menu == .vault))
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityLabel("Vault")
            .accessibilityValue(vault.name)
            .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                editor.menu == .vault ? [.vault: $0] : [:]
            }
            .padding(.leading, -Metrics.close)
            Spacer(minLength: 0)
            Button("Cancel", action: panes.cancelEdit)
                .buttonStyle(QuietButtonStyle())
                // The question has an Esc of its own while it is up.
                .keyboardShortcut(panes.isAskingToDiscard ? nil : .cancelAction)
            Button("Save") { panes.saveEdit() }
                .buttonStyle(FilledButtonStyle())
                // Faint until there is something to save.
                .opacity(editor.isDirty && editor.canSave ? 1 : Palette.disabled)
                .disabled(!editor.canSave)
                .accessibilityValue(editor.isDirty ? "changed" : "unchanged")
        }
        .padding(.leading, Metrics.wide + Metrics.wide)
        .padding(.trailing, Metrics.gap)
        .frame(height: Metrics.listHeader)
    }

    private func lit(_ isOpen: Bool) -> some View {
        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
            .fill(isOpen ? Palette.listSelection : Palette.listSelection.opacity(0))
    }

    // MARK: The icon and the title

    private var header: some View {
        HStack(spacing: Metrics.wide) {
            ItemIcon(item: editor.original, icons: panes.icons, side: Metrics.detailIcon)
                .overlay(alignment: .bottomTrailing) { star }
            input("title", $editor.form.title, row: Self.titleRow, prompt: "Title", font: Fonts.title)
                .padding(.horizontal, Metrics.gap)
                .frame(minHeight: Metrics.detailIcon)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
                        .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
                )
                .overlay { KeyRing(isOn: focus == Self.titleRow) }
        }
        .padding(.leading, Metrics.wide)
        .padding(.vertical, Metrics.close)
    }

    /// The favourite's star on the icon's corner, as the details have it,
    /// and here a button: hollow while the item is not one.
    private var star: some View {
        let isOn = editor.form.isFavourite
        return Button { editor.form.isFavourite.toggle() } label: {
            ZStack {
                Glyph.star.image.font(Fonts.detailStarEdge).foregroundStyle(Palette.content)
                (isOn ? Glyph.star : Glyph.favorites).image
                    .font(Fonts.detailStar)
                    .foregroundStyle(isOn ? Palette.star : Palette.faintText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: Metrics.starOverhang, y: Metrics.starOverhang)
        .accessibilityLabel("Favourite")
        .accessibilityValue(isOn ? "yes" : "no")
    }

    // MARK: The outlined group

    @ViewBuilder
    private var login: some View {
        EditRow(label: editor.form.usernameWord, hasKeys: focus == Self.usernameRow) {
            input(editor.form.usernameWord, $editor.form.username, row: Self.usernameRow, prompt: "name or email")
        } trailing: {
            EmptyView()
        }
        Hairline(.horizontal)
        EditRow(label: "password", hasKeys: focus == Editor.passwordRow) {
            hidden("password", $editor.form.password, row: Editor.passwordRow, prompt: "none")
        } trailing: {
            if let strength = editor.strength {
                HStack(spacing: Metrics.close) {
                    Text(strength.word)
                        .font(Fonts.rowSecond)
                        .foregroundStyle(Palette.secondText)
                        .lineLimit(1)
                    StrengthRing(strength: strength)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("strength")
                .accessibilityValue(strength.word)
                .accessibilityAddTraits(.isStaticText)
            }
            eye(Editor.passwordRow)
            IconButton(glyph: .generate, name: "Generate Password", action: panes.toggleFieldGenerator)
                .background(lit(panes.generator?.purpose == .field))
                .anchorPreference(key: GeneratorAnchor.self, value: .bounds) {
                    panes.generator?.purpose == .field ? $0 : nil
                }
        }
        Hairline(.horizontal)
        EditRow(label: "one-time code", hasKeys: focus == Editor.totpRow) {
            hidden("one-time code", $editor.form.totp, row: Editor.totpRow, prompt: "the secret, or an otpauth:// address")
        } trailing: {
            eye(Editor.totpRow)
        }
        // A passkey is the site's to make and to take away. It is shown,
        // and goes back as it came.
        ForEach(Array((editor.original.login?.passkeysCreated ?? []).enumerated()), id: \.offset) { _, made in
            Hairline(.horizontal)
            EditRow(label: "passkey", hasKeys: false) {
                Text(ItemDetail.passkeySaid(made))
                    .font(Fonts.body)
                    .foregroundStyle(Palette.secondText)
            } trailing: {
                EmptyView()
            }
        }
    }

    // MARK: A card

    @ViewBuilder
    private var card: some View {
        let held = editor.form.card
        plain("cardholder name", $editor.form.card.holder, row: "holder", prompt: "the name on the card")
        Hairline(.horizontal)
        EditRow(label: "brand", hasKeys: false) {
            MenuButton(word: held.brand.isEmpty ? Self.none : held.brand, name: "brand",
                       isOpen: editor.menu == .brand) {
                editor.toggle(.brand)
            }
            .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                editor.menu == .brand ? [.brand: $0] : [:]
            }
        } trailing: {
            EmptyView()
        }
        Hairline(.horizontal)
        EditRow(label: "number", hasKeys: focus == Editor.numberRow) {
            guarded("number", $editor.form.card.number, row: Editor.numberRow, prompt: "none") {
                if let last = Card.lastFour(of: held.number) {
                    HStack(spacing: Metrics.tight) {
                        FormDots(ItemDetail.numberDots)
                        Text(last).font(Fonts.code)
                    }
                } else {
                    FormDots(ItemDetail.dots)
                }
            }
        } trailing: {
            eye(Editor.numberRow)
        }
        Hairline(.horizontal)
        EditRow(label: "expiry date", hasKeys: focus == Self.yearRow) {
            HStack(spacing: Metrics.close) {
                MenuButton(word: held.month.isEmpty ? "month" : Card.month(held.month), name: "expiry month",
                           isOpen: editor.menu == .month) {
                    editor.toggle(.month)
                }
                .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                    editor.menu == .month ? [.month: $0] : [:]
                }
                Text("/").font(Fonts.body).foregroundStyle(Palette.prompt).accessibilityHidden(true)
                input("expiry year", $editor.form.card.year, row: Self.yearRow, prompt: "year")
            }
        } trailing: {
            EmptyView()
        }
        Hairline(.horizontal)
        EditRow(label: "security code", hasKeys: focus == Editor.codeRow) {
            guarded("security code", $editor.form.card.code, row: Editor.codeRow, prompt: "none") {
                FormDots(ItemDetail.dots)
            }
        } trailing: {
            eye(Editor.codeRow)
        }
    }

    // MARK: An identity

    private var identity: some View {
        let rows = EditorForm.identityRows
        return ForEach(Array(rows.enumerated()), id: \.offset) { place, keys in
            if place > 0 { Hairline(.horizontal) }
            HStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    part(key)
                        .overlay(alignment: .trailing) {
                            if key != keys.last { Hairline(.vertical) }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func part(_ key: Identity.Key) -> some View {
        let row = Editor.row(of: key)
        let text = Binding { editor.form.identity[key] ?? "" } set: { editor.form.identity[key] = $0 }
        if key.isHidden {
            EditRow(label: key.label, hasKeys: focus == row) {
                hidden(key.label, text, row: row, prompt: "none")
            } trailing: {
                eye(row)
            }
        } else {
            plain(key.label, text, row: row, prompt: "none")
        }
    }

    // MARK: A key

    /// The private half is not typed into: the button takes a whole new
    /// key off the pasteboard, and the two rows over it then say what that
    /// key's are.
    private var key: some View {
        let held = editor.form.key
        return VStack(alignment: .leading, spacing: Metrics.close) {
            Outlined {
                said("public key", held.publicKey)
                Hairline(.horizontal)
                said("fingerprint", held.fingerprint)
                Hairline(.horizontal)
                EditRow(label: "private key", hasKeys: false) {
                    if editor.hasNewKey {
                        Text("a new key, kept when the form is saved")
                            .font(Fonts.body)
                            .foregroundStyle(Palette.text)
                    } else if held.privateKey.isEmpty {
                        Text("none").font(Fonts.body).foregroundStyle(Palette.prompt)
                    } else {
                        FormDots(ItemDetail.dots)
                            .foregroundStyle(Palette.text)
                            .accessibilityElement()
                            .accessibilityLabel(ItemDetail.concealed)
                    }
                } trailing: {
                    Button("Paste a New Key") { panes.pasteKey() }
                        .buttonStyle(QuietButtonStyle())
                        .padding(.trailing, Metrics.close)
                }
            }
            if let refusal = editor.keyRefusal {
                Text(refusal)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.wide)
            }
        }
    }

    /// A row that says something the form does not take from the keys.
    private func said(_ label: String, _ value: String) -> some View {
        EditRow(label: label, hasKeys: false) {
            Text(value.isEmpty ? "none" : value)
                .font(value.isEmpty ? Fonts.body : Fonts.code)
                .foregroundStyle(value.isEmpty ? Palette.prompt : Palette.secondText)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            EmptyView()
        }
    }

    // MARK: The addresses

    private var websites: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(editor.form.addresses) { address in
                let row = "website-\(address.id)"
                EditRow(label: "website", hasKeys: focus == row, isFree: true) {
                    input("website", self.address(address.id).uri, row: row, prompt: "example.com")
                } trailing: {
                    MenuButton(word: address.match?.name ?? URIMatch.defaultName, name: "Match",
                               isOpen: editor.menu == .match(address.id)) {
                        editor.toggle(.match(address.id))
                    }
                    .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                        editor.menu == .match(address.id) ? [.match(address.id): $0] : [:]
                    }
                    IconButton(glyph: .remove, name: "Remove Website") { editor.removeAddress(address.id) }
                }
            }
            AddButton(word: "add a website", action: editor.addAddress)
        }
    }

    // MARK: The custom fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(editor.form.fields) { field in
                let row = Editor.row(ofField: field.id)
                let name = "\(row)-name"
                HStack(spacing: Metrics.close) {
                    VStack(alignment: .leading, spacing: Metrics.hair) {
                        input("label", self.field(field.id).name, row: name, prompt: "label", font: Fonts.label,
                              colour: Palette.label)
                        value(of: field, row: row)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if field.kind == .hidden { eye(row) }
                    IconButton(glyph: .chevronUp, name: "Move Up", works: field.id != editor.form.fields.first?.id) {
                        editor.moveField(field.id, by: -1)
                    }
                    IconButton(glyph: .chevronDown, name: "Move Down",
                               works: field.id != editor.form.fields.last?.id) {
                        editor.moveField(field.id, by: 1)
                    }
                    IconButton(glyph: .remove, name: "Remove Field") { editor.removeField(field.id) }
                }
                .modifier(EditRowGround(hasKeys: focus == row || focus == name, isFree: true))
            }
            AddButton(word: "add more") { editor.toggle(.addField) }
                .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                    editor.menu == .addField ? [.addField: $0] : [:]
                }
        }
    }

    @ViewBuilder
    private func value(of field: EditorForm.CustomField, row: String) -> some View {
        switch field.kind {
        case .text:
            input(field.name, self.field(field.id).value, row: row, prompt: "value")
        case .hidden:
            hidden(field.name, self.field(field.id).value, row: row, prompt: "value")
        case .boolean:
            Toggle("", isOn: self.field(field.id).isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(field.name)
        case .linked:
            MenuButton(word: ItemDetail.linked(field.linkedID, username: editor.form.username), name: field.name, glyph: .link,
                       isOpen: editor.menu == .linked(field.id)) {
                editor.toggle(.linked(field.id))
            }
            .anchorPreference(key: EditorMenuAnchor.self, value: .bounds) {
                editor.menu == .linked(field.id) ? [.linked(field.id): $0] : [:]
            }
        }
    }

    // MARK: The notes

    private var notes: some View {
        Outlined {
            VStack(alignment: .leading, spacing: Metrics.tight) {
                FieldLabel("notes")
                TextEditor(text: $editor.form.notes)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: Metrics.editorNotes)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, -Metrics.textInset)
                    .focused($focus, equals: Self.notesRow)
                    .accessibilityLabel("notes")
            }
            .padding(.horizontal, Metrics.wide)
            .padding(.vertical, Metrics.gap)
        }
        .overlay { KeyRing(isOn: focus == Self.notesRow) }
    }

    // MARK: Asking again

    static let asksAgain = "Ask again before this item is used"

    /// The switch that sets Bitwarden's `reprompt`, at the foot of the
    /// form: what it is called, what it does in grey, and the switch.
    private var asking: some View {
        HStack(spacing: Metrics.gap) {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                Text(Self.asksAgain)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                Text("A finger, or the master password, before it is revealed, copied, changed or typed into another app.")
                    .font(Fonts.label)
                    .foregroundStyle(Palette.secondText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.gap)
            Switch(isOn: $editor.form.asksAgain, name: Self.asksAgain)
        }
        .padding(.horizontal, Metrics.wide)
    }

    // MARK: What is typed into

    private func input(_ name: String, _ text: Binding<String>, row: String, prompt: String,
                       font: Font = Fonts.body, colour: Color = Palette.text) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.prompt))
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(colour)
            .focused($focus, equals: row)
            // A custom field that has no name yet is still a field.
            .accessibilityLabel(name.isEmpty ? prompt : name)
    }

    private func plain(_ label: String, _ text: Binding<String>, row: String, prompt: String) -> some View {
        EditRow(label: label, hasKeys: focus == row) {
            input(label, text, row: row, prompt: prompt)
        } trailing: {
            EmptyView()
        }
    }

    /// A value that is spelled out while the caret is in it and is `dots`
    /// the rest of the time, to the eye and to VoiceOver alike. It is one
    /// field throughout, so the caret that shows it is not lost in showing
    /// it; the eye shows it too.
    private func guarded<Dots: View>(_ name: String, _ text: Binding<String>, row: String, prompt: String,
                                     @ViewBuilder dots: () -> Dots) -> some View {
        let isShown = focus == row || editor.revealed.contains(row) || text.wrappedValue.isEmpty
        return input(name, text, row: row, prompt: prompt, font: Fonts.code,
                     colour: isShown ? Palette.text : Palette.text.opacity(0))
            .accessibilityValue(isShown ? text.wrappedValue : ItemDetail.concealed)
            .overlay(alignment: .leading) {
                if !isShown {
                    dots()
                        .foregroundStyle(Palette.text)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// A value that is dots until its eye is clicked, and then is spelled
    /// in the fixed-width face a revealed value has in the details.
    @ViewBuilder
    private func hidden(_ name: String, _ text: Binding<String>, row: String, prompt: String) -> some View {
        if editor.revealed.contains(row) {
            input(name, text, row: row, prompt: prompt, font: Fonts.code)
        } else {
            SecureField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.prompt))
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .focused($focus, equals: row)
                .accessibilityLabel(name.isEmpty ? prompt : name)
        }
    }

    private func eye(_ row: String) -> some View {
        let isShown = editor.revealed.contains(row)
        return IconButton(glyph: isShown ? .conceal : .reveal, name: isShown ? "Conceal" : "Reveal") {
            editor.toggleRevealed(row)
        }
    }

    /// A row of the form is found again by its id and not by its place, so
    /// a field that has just been removed is typed into by nothing.
    private func address(_ id: Int) -> Binding<EditorForm.Address> {
        Binding {
            editor.form.addresses.first { $0.id == id } ?? .init(id: id, uri: "", match: nil)
        } set: { changed in
            guard let place = editor.form.addresses.firstIndex(where: { $0.id == id }) else { return }
            editor.form.addresses[place] = changed
        }
    }

    private func field(_ id: Int) -> Binding<EditorForm.CustomField> {
        Binding {
            editor.form.fields.first { $0.id == id } ?? .init(id: id, name: "", value: "", kind: .text)
        } set: { changed in
            guard let place = editor.form.fields.firstIndex(where: { $0.id == id }) else { return }
            editor.form.fields[place] = changed
        }
    }
}

// MARK: - A row

/// What a row of the details has around it, without the fill and the word
/// that say it copies: here a click puts the caret in it.
private struct EditRowGround: ViewModifier {
    let hasKeys: Bool
    var isFree = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, Metrics.wide)
            .padding(.trailing, Metrics.close)
            .padding(.vertical, Metrics.close)
            .frame(maxWidth: .infinity, minHeight: Metrics.fieldRow, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: isFree ? Metrics.groupRadius : 0, style: .continuous)
                    .strokeBorder(hasKeys ? Palette.accent : Palette.accent.opacity(0), lineWidth: Metrics.dropRing)
                    .allowsHitTesting(false)
            }
    }
}

/// The small label over what is typed, and at the right whatever the row
/// can do besides.
private struct EditRow<Content: View, Trailing: View>: View {
    let label: String
    let hasKeys: Bool
    var isFree = false
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Metrics.close) {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                FieldLabel(label)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .modifier(EditRowGround(hasKeys: hasKeys, isFree: isFree))
    }
}

/// A glyph that is a button, the height of the strip's.
private struct IconButton: View {
    let glyph: Glyph
    let name: String
    var works = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(works ? Palette.secondText : Palette.faintText)
                .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!works)
        .accessibilityLabel(name)
    }
}

/// A word and a chevron on the field's grey, which drops one of the form's
/// menus.
private struct MenuButton: View {
    let word: String
    let name: String
    var glyph: Glyph?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.tight) {
                if let glyph { glyph.image.font(Fonts.disclosure) }
                Text(word).font(Fonts.rowSecond).lineLimit(1)
                Glyph.chevronDown.image.font(Fonts.disclosure)
            }
            .foregroundStyle(Palette.secondText)
            .padding(.horizontal, Metrics.close)
            .frame(height: Metrics.buttonHeight - Metrics.tight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(isOpen ? Palette.listSelection : Palette.field)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(name)
        .accessibilityValue(word)
    }
}

/// "add a website" and "add more": a plus and the words, in the accent, at
/// the foot of what they add to.
private struct AddButton: View {
    let word: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.tight) {
                Glyph.add.image.font(Fonts.disclosure)
                Text(word).font(Fonts.body)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Metrics.wide)
            .frame(height: Metrics.itemMenuRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The menus

/// Where the buttons that drop a menu stand in the column.
struct EditorMenuAnchor: PreferenceKey {
    static let defaultValue: [EditorMenu: Anchor<CGRect>] = [:]

    static func reduce(value: inout [EditorMenu: Anchor<CGRect>], nextValue: () -> [EditorMenu: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

/// The form's open menu, hung under its button, or over it when the column
/// ends first. A click anywhere else puts it away.
private struct EditorMenuLayer: View {
    @ObservedObject var panes: Panes
    @ObservedObject var editor: Editor
    let anchors: [EditorMenu: Anchor<CGRect>]

    private struct Row: Identifiable {
        let id: Int
        let name: String
        var isTicked = false
        var glyph: Glyph?
        let choose: () -> Void
    }

    var body: some View {
        if let menu = editor.menu {
            GeometryReader { column in
                ZStack(alignment: .topLeading) {
                    Palette.content.opacity(0)
                        .contentShape(Rectangle())
                        .onTapGesture { editor.menu = nil }
                        .accessibilityHidden(true)
                    if let anchor = anchors[menu] {
                        let button = column[anchor]
                        let height = self.height(of: menu)
                        let below = button.maxY + Metrics.tight
                        let fits = below + height + Metrics.close <= column.size.height
                        let rightmost = column.size.width - Metrics.menuWidth - Metrics.close
                        let left = hangsRight(menu) ? button.maxX - Metrics.menuWidth : button.minX - Metrics.close
                        card(menu)
                            .offset(x: max(Metrics.close, min(left, rightmost)),
                                    y: fits ? below : max(Metrics.close, button.minY - Metrics.tight - height))
                    }
                }
            }
        }
    }

    /// The menus behind a button at a row's right end keep to that end.
    private func hangsRight(_ menu: EditorMenu) -> Bool {
        if case .match = menu { return true }
        return false
    }

    @ViewBuilder
    private func card(_ menu: EditorMenu) -> some View {
        switch menu {
        case .vault:
            MoveMenuCard(vaults: panes.moveTargets,
                         current: editor.form.folderID.map(Vault.Place.folder) ?? .personal) { place in
                editor.menu = nil
                switch place {
                case .personal: editor.form.folderID = nil
                case .folder(let id): editor.form.folderID = id
                case .collection: break
                }
            }
        default:
            let rows = self.rows(of: menu)
            VStack(alignment: .leading, spacing: 0) {
                if let heading = heading(of: menu) {
                    Text(heading)
                        .font(Fonts.heading)
                        .tracking(Metrics.headingTracking)
                        .foregroundStyle(Palette.secondText)
                        .padding(.horizontal, Metrics.wide)
                        .frame(height: Metrics.menuRow)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(rows) { row in
                    DetailMenuRow(name: row.name, isTicked: row.isTicked, choose: row.choose) {
                        if let glyph = row.glyph {
                            glyph.image.font(Fonts.sidebarGlyph).foregroundStyle(Palette.secondText)
                        }
                    }
                }
            }
            .modifier(MenuGround(width: Metrics.menuWidth))
        }
    }

    private func heading(of menu: EditorMenu) -> String? {
        switch menu {
        case .vault: return "MOVE TO"
        case .brand: return "BRAND"
        case .month: return "EXPIRES IN"
        case .match: return "MATCH BY"
        case .linked: return "THE SAME AS"
        case .addField: return nil
        }
    }

    private func rows(of menu: EditorMenu) -> [Row] {
        switch menu {
        case .vault:
            return []
        case .brand:
            let current = editor.form.card.brand
            // A brand the list does not have is the item's own, and stays
            // on offer.
            let brands = Card.brands + (current.isEmpty || Card.brands.contains(current) ? [] : [current])
            return [Row(id: -1, name: "None", isTicked: current.isEmpty) { editor.brand("") }]
                + brands.enumerated().map { place, brand in
                    Row(id: place, name: brand, isTicked: current == brand) { editor.brand(brand) }
                }
        case .month:
            let current = Int(editor.form.card.month.trimmingCharacters(in: .whitespaces))
            return [Row(id: 0, name: "None", isTicked: editor.form.card.month.isEmpty) { editor.month(nil) }]
                + Card.months.enumerated().map { place, name in
                    Row(id: place + 1, name: "\(Card.month(String(place + 1)))  \(name)", isTicked: current == place + 1) {
                        editor.month(place + 1)
                    }
                }
        case .match(let id):
            let current = editor.form.addresses.first { $0.id == id }?.match
            return [Row(id: -1, name: URIMatch.defaultName, isTicked: current == nil) { editor.match(id, by: nil) }]
                + URIMatch.allCases.map { rule in
                    Row(id: rule.rawValue, name: rule.name, isTicked: current == rule) { editor.match(id, by: rule) }
                }
        case .linked(let id):
            let current = editor.form.fields.first { $0.id == id }?.linkedID
            return editor.linkable.map { target in
                Row(id: target.id, name: target.name, isTicked: current == target.id) {
                    editor.link(id, to: target.id)
                }
            }
        case .addField:
            let glyphs: [Field.Kind: Glyph] = [.text: .largeType, .hidden: .conceal, .boolean: .tick, .linked: .link]
            return editor.fieldKinds.map { kind in
                Row(id: kind.rawValue, name: kind.name, glyph: glyphs[kind]) { editor.addField(kind) }
            }
        }
    }

    private func height(of menu: EditorMenu) -> CGFloat {
        let rows = menu == .vault ? panes.moveTargets.count : self.rows(of: menu).count
        return CGFloat(rows) * Metrics.itemMenuRow + (heading(of: menu) == nil ? 0 : Metrics.menuRow)
            + Metrics.close + Metrics.close
    }
}

// MARK: - The question

/// The question between Cancel and a form with something changed in it
/// being gone.
struct DiscardQuestion: View {
    let title: String
    /// The form is of an item that was never saved, which has no name but
    /// the one in the form and nothing to stay as it was.
    var isNew = false
    var keep: () -> Void = {}
    var discard: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim.ignoresSafeArea()
            VStack(spacing: Metrics.loose) {
                Glyph.edit.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.secondText)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.close) {
                    Text(isNew ? "Discard this new item?" : "Discard the changes to “\(title)”?")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text(isNew
                        ? "What was typed into the form has not been saved. Discarded, it is gone, and no item is made."
                        : "What was typed into the form has not been saved. Discarded, it is gone, and the item stays as it was.")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.gap) {
                    Button("Keep Editing", action: keep)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(isNew ? "Discard Item" : "Discard Changes", action: discard)
                        .buttonStyle(FilledButtonStyle(ground: Palette.redLit))
                }
            }
            .padding(Metrics.apart)
            .frame(width: Metrics.offerWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        }
        .ignoresSafeArea()
    }
}

/// A hidden value the form draws itself, in dots the size of the bullets
/// a secure field draws for the ones it holds, so that a card's code and a
/// login's password are hidden alike. It is as tall as a line of the body
/// face, whatever the dots' own face is.
private struct FormDots: View {
    let dots: String

    init(_ dots: String) {
        self.dots = dots
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(" ").font(Fonts.body).hidden()
            Text(dots)
                .font(Fonts.formDots)
                .tracking(Metrics.formDotsTracking)
                .fixedSize()
                .frame(height: 0)
                .offset(y: -Metrics.formDotsLift)
        }
    }
}

// MARK: - Shots

extension Surface {
    private static func editing(_ name: String, of title: String, height: CGFloat = Metrics.windowSize.height,
                                _ arrange: @escaping @MainActor (Panes, Editor) -> Void = { _, _ in }) -> Surface {
        Surface(name: name, size: CGSize(width: Metrics.windowSize.width, height: height)) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(item: store.shelves.all.first { $0.item.name == title }?.id)
            panes.beginEdit()
            if let editor = panes.editor { arrange(panes, editor) }
            return AnyView(PanesView(panes: panes))
        }
    }

    private static let tall = Metrics.windowSize.height + Metrics.windowSize.height / 2

    /// The other four types' forms as ⌘E leaves them; a card's with its
    /// number shown and the months dropped; and a key's after a paste.
    static let otherEditors: [Surface] = [
        editing("editor-card", of: "Bonus Kart"),
        editing("editor-identity", of: "Deniz Yılmaz", height: tall),
        editing("editor-note", of: "Yazılım lisansı"),
        editing("editor-ssh", of: "Sunucu anahtarı"),
        editing("editor-card-month", of: "Maximum") { _, editor in
            editor.toggleRevealed(Editor.numberRow)
            editor.toggle(.month)
        },
        editing("editor-ssh-pasted", of: "Sunucu anahtarı") { _, editor in
            editor.replaceKey(with: DemoVault.pastedKey)
        },
        editing("editor-ssh-refused", of: "Git imza anahtarı") { _, editor in
            editor.replaceKey(with: DemoVault.keyFile(cipher: "aes256-ctr"))
        },
    ]

    /// The form as ⌘E leaves it, on the login that has one of everything;
    /// the same with a title, a password, an address and a field changed,
    /// so Save is lit; the question Esc asks of a form like that; a match
    /// rule's menu open; "add more"; the banner over a form whose item was
    /// changed somewhere else; and the first form again with a name typed
    /// where the address was, at which the field and the linked field's
    /// button both say username.
    static let editors: [Surface] = [
        editing("editor-clean", of: "İş Bankası", height: tall),
        editing("editor-username", of: "İş Bankası", height: tall) { _, editor in
            editor.form.username = "deniz.yilmaz"
        },
        editing("editor-dirty", of: "İş Bankası", height: tall) { _, editor in
            editor.form.title = "İş Bankası (ortak)"
            editor.form.password = DemoVault.typed
            editor.toggleRevealed(Editor.passwordRow)
            editor.match(editor.form.addresses[0].id, by: .host)
            editor.addAddress()
            editor.removeField(editor.form.fields[2].id)
            editor.addField(.hidden)
            editor.form.isFavourite = false
        },
        editing("editor-question", of: "Spotify") { panes, editor in
            editor.form.username = "deniz.yilmaz@\(DemoVault.usernameDomain)"
            panes.cancelEdit()
        },
        editing("editor-match", of: "İş Bankası") { _, editor in
            editor.toggle(.match(editor.form.addresses[1].id))
        },
        editing("editor-add", of: "Spotify") { _, editor in
            editor.addField(.text)
            editor.toggle(.addField)
        },
        editing("editor-changed", of: "Spotify") { _, editor in
            editor.form.username = "deniz.yilmaz@\(DemoVault.usernameDomain)"
            editor.rebase(onto: editor.original)
        },
    ]
}

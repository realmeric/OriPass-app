import CoreGraphics

/// Every distance the app lays out with, in points. A number in a view is a
/// smell, and `DesignLiteralTests` reads the sources to hold it: a surface
/// that needs a measurement that is not here needs a name here first.
///
/// The stills settle proportion and not points (`docs/look.md`), so these are
/// chosen to give the stills' proportions at the window's default size.
enum Metrics {
    /// ⌘+ and ⌘- move this through `Zoom`'s three steps, by way of the door.
    /// Everything that scales reads it through `scaled`.
    static var zoom: CGFloat = 1

    static func scaled(_ points: CGFloat) -> CGFloat { (points * zoom).rounded() }

    /// The Appearance room's Density, by way of the door. A row's height is
    /// read through `row` and a padding that gives way through `room`.
    static var density = Density.comfortable

    static func row(_ points: CGFloat) -> CGFloat { scaled(points * density.rows) }
    static func room(_ points: CGFloat) -> CGFloat { scaled(points * density.room) }

    // MARK: - The window

    static let windowSize = CGSize(width: 1120, height: 700)
    static let windowMinimum = CGSize(width: 760, height: 460)
    /// A window of one item (⌘O): the details column at the main window's
    /// own size, and a little shorter than it.
    static let itemWindow = CGSize(width: 532, height: 620)

    /// About a quarter of the window, a little more than a quarter, and the
    /// rest (`docs/look.md`, "The window").
    static let sidebarWidth: CGFloat = 264
    static let sidebarMinimum: CGFloat = 200
    static let listWidth: CGFloat = 324
    static let listMinimum: CGFloat = 250
    static let detailMinimum: CGFloat = 340

    static let toolbarHeight: CGFloat = 52
    /// Room for the traffic lights above the sidebar's first row.
    static let titlebarInset: CGFloat = 44
    /// From the window's edge to where a toolbar may start once the sidebar
    /// has folded and the traffic lights stand over it.
    static let trafficLights: CGFloat = 92
    static let hairline: CGFloat = 1

    // MARK: - Spacing

    static var hair: CGFloat { scaled(2) }
    static var tight: CGFloat { scaled(4) }
    /// What brings a form's drawn dots as close together as a secure
    /// field's bullets (`Fonts.formDots`).
    static var formDotsTracking: CGFloat { -1.5 * zoom }
    /// And what puts them on the line the bullets are on.
    static var formDotsLift: CGFloat { scaled(1) }
    static var close: CGFloat { scaled(8) }
    static var gap: CGFloat { room(12) }
    static var wide: CGFloat { room(16) }
    static var loose: CGFloat { room(24) }
    static var apart: CGFloat { room(32) }

    // MARK: - Rows and icons

    static var sidebarRow: CGFloat { row(34) }
    /// The column a row's mark is centred in, so the labels line up under
    /// one another whatever leads them.
    static var sidebarMark: CGFloat { scaled(20) }
    /// The account's row, between the traffic lights and the first hairline.
    static var sidebarHeader: CGFloat { scaled(48) }
    static var sidebarAvatar: CGFloat { scaled(26) }
    static var vaultDot: CGFloat { scaled(12) }
    /// How far apart the letters of a heading in capitals stand.
    static let headingTracking: CGFloat = 0.6
    /// An icon about two lines of text tall, and a row with air around it.
    static var listRow: CGFloat { row(50) }
    static var listIcon: CGFloat { scaled(32) }
    static var listHeading: CGFloat { row(38) }
    /// The strip over the rows, with the category at its left and the two
    /// glyph buttons at its right.
    static var listHeader: CGFloat { row(44) }
    /// How far the star hangs over the icon's lower right corner.
    static var starOverhang: CGFloat { scaled(4) }
    /// A menu the list's header drops: its width, a row of it, and how far
    /// its shadow spreads.
    static var menuWidth: CGFloat { scaled(216) }
    static var menuRow: CGFloat { row(30) }
    static let menuShadow: CGFloat = 14
    /// The item's menu, wide enough for its longest row behind a glyph, and
    /// a row of it, with the air the still gives each.
    static var itemMenuWidth: CGFloat { scaled(248) }
    static var itemMenuRow: CGFloat { row(32) }
    static var detailIcon: CGFloat { scaled(56) }
    static var fieldRow: CGFloat { row(48) }
    /// The square at a hovered row's right end that opens its menu.
    static var fieldButton: CGFloat { scaled(44) }
    /// How far apart the dots of a hidden value stand.
    static let dotTracking: CGFloat = 1.5
    /// In a note: how far a list's row stands in for each level it is
    /// nested, and the grey bar at a quotation's left.
    static var noteIndent: CGFloat { scaled(18) }
    static var quoteBar: CGFloat { scaled(3) }
    static var star: CGFloat { scaled(12) }
    static var controlGlyph: CGFloat { scaled(14) }
    /// The least height of the notes while they are being typed.
    static var editorNotes: CGFloat { scaled(96) }
    /// What a text view keeps to the left of its first letter.
    static let textInset: CGFloat = 5
    static var ring: CGFloat { scaled(16) }
    static var ringLine: CGFloat { scaled(2.5) }
    /// The ring that says how long a one-time code has left, a little
    /// smaller than a strength's, and its line.
    static var codeRing: CGFloat { scaled(13) }
    static var codeRingLine: CGFloat { scaled(2.25) }
    /// The dot between a code's two groups.
    static var codeDot: CGFloat { scaled(4) }
    /// A code is shown in red for the last of its seconds.
    static let codeLastSeconds = 5

    /// The mark in the middle of a details column with no item in it.
    static var emptyMark: CGFloat { scaled(72) }

    // MARK: - Corners

    static var rowRadius: CGFloat { scaled(7) }
    static var groupRadius: CGFloat { scaled(10) }
    static var controlRadius: CGFloat { scaled(6) }
    static var panelRadius: CGFloat { scaled(14) }
    /// A rounded-square icon's corner, as a share of its side.
    static let iconCorner: CGFloat = 0.24

    // MARK: - The lock screen

    static var lockMark: CGFloat { scaled(84) }
    /// The pass on the round mark, as a share of the disc.
    static let lockMarkShare: CGFloat = 0.6
    static var lockField: CGSize { CGSize(width: scaled(300), height: scaled(36)) }
    static var lockFieldRadius: CGFloat { scaled(8) }
    static var lockFinger: CGFloat { scaled(20) }
    /// The widest a sentence runs when the lock screen has something to say
    /// in place of the field.
    static var lockSentence: CGFloat { scaled(440) }
    /// How far the field travels when a password is refused.
    static let shake: CGFloat = 9
    /// The sheet that signs an account in.
    static var signInWidth: CGFloat { scaled(400) }

    /// A row of the password history, and how many of them the sheet shows
    /// before it scrolls.
    static var historyRow: CGFloat { row(56) }
    static let historyRowsShown: CGFloat = 5.5

    /// The panel Quick Look shows an attachment in, as it opens and at its
    /// smallest.
    static let previewSize = CGSize(width: 760, height: 560)
    static let previewMinimum = CGSize(width: 320, height: 240)

    /// The card that asks whether a finger should open the vault.
    static var offerWidth: CGFloat { scaled(380) }
    static var offerGlyph: CGFloat { scaled(44) }

    /// The card over ssh: as wide as a fingerprint needs, the asking app's
    /// icon and the key's tile on its corner, and the line along its foot.
    static var agentWidth: CGFloat { scaled(470) }
    static var agentIcon: CGFloat { scaled(76) }
    static var agentBadge: CGFloat { scaled(30) }
    static var agentBadgeEdge: CGFloat { scaled(2) }
    static var agentRowInset: CGFloat { scaled(10) }
    static var agentLine: CGFloat { scaled(3) }
    /// What `LAAuthenticationView` draws at `.regular`, whatever its frame,
    /// so it does not follow the zoom.
    static let agentFinger: CGFloat = 64

    /// What OriPass asks the system to show of the sheet its Passwords menu
    /// raises.
    static let autoFillSheet = CGSize(width: 420, height: 340)

    // MARK: - Large Type

    /// One character and the number under it. Not scaled: it is read from
    /// across the room whatever the window's zoom is.
    static let largeTypeCell = CGSize(width: 46, height: 100)
    static let largeTypePad: CGFloat = 24
    /// How much of the screen's width and height the panel may take.
    static let largeTypeShare: CGFloat = 0.8
    static let largeTypeShadow: CGFloat = 30

    // MARK: - Quick Access

    /// The panel and the field in it. Not scaled: the panel is built once,
    /// at launch, and is over another app more often than beside the window
    /// whose size was chosen.
    static let quickWidth: CGFloat = 600
    static let quickPad: CGFloat = 8
    static let quickField: CGFloat = 42
    static let quickFieldRadius: CGFloat = 8
    static let quickRadius: CGFloat = 12
    static let quickGlyph: CGFloat = 18
    /// How far down the screen its top edge is, as a share of the height.
    /// The top and not the middle, so the field stays where it is when the
    /// results grow under it.
    static let quickFall: CGFloat = 1.0 / 3
    /// A result, the icon in it, and the square at its right end that
    /// opens the actions.
    static let quickRow: CGFloat = 36
    static let quickIcon: CGFloat = 20
    static let quickRowRadius: CGFloat = 6
    static let quickMore: CGFloat = 30
    /// The name over the suggested rows, and over the used ones after them.
    static let quickHeading: CGFloat = 24
    /// The strip of keys under the results.
    static let quickHints: CGFloat = 40
    static let quickKeycap: CGFloat = 22
    static let quickKeycapRadius: CGFloat = 5
    /// An opened item: its header, one action, a rule with the room around
    /// it, and the strip that says where the item lives.
    static let quickHeader: CGFloat = 60
    static let quickHeaderIcon: CGFloat = 34
    static let quickAction: CGFloat = 32
    static let quickRule: CGFloat = 13
    static let quickFooter: CGFloat = 38
    /// The row the lock is drawn in, and the field in it.
    static let quickLock: CGFloat = 56
    static let quickLockField: CGFloat = 36
    static let quickLockMark: CGFloat = 26
    /// The notice under the field: a title and a sentence of two lines.
    static let quickNotice: CGFloat = 76
    /// A shot of the panel: tall enough for the tallest it gets.
    static let quickShot = CGSize(width: 600, height: 500)
    /// The card that asks for the master password again, with air around
    /// it.
    static let passwordCardShot = CGSize(width: 430, height: 380)
    /// The card over ssh, with the same air.
    static let agentCardShot = CGSize(width: 530, height: 760)
    static let passReportShot = CGSize(width: 640, height: 100)
    /// The space between two things on one line of the panel.
    static let quickGap: CGFloat = 10

    // MARK: - The menu bar

    /// The mark's square in the bar. The bar's own height is the system's;
    /// the mark is a little under it and is centred in it.
    static let menuBarMark: CGFloat = 18
    /// The menu the mark drops, drawn for a shot: its width, a row, the
    /// room above the first and under the last, and the rule's. The system
    /// draws the real one, so these are the stills' proportions and not
    /// the system's points.
    static let statusMenuWidth: CGFloat = 230
    static let statusMenuRow: CGFloat = 24
    static let statusMenuPad: CGFloat = 6
    static let statusMenuRule: CGFloat = 13
    static let statusMenuRadius: CGFloat = 10
    /// The strip the mark stands in, in a shot, and the square that lights
    /// behind the mark while its menu is open.
    static let statusBarHeight: CGFloat = 30
    static let statusBarMark: CGSize = CGSize(width: 34, height: 26)
    static let statusMenuShot = CGSize(width: 330, height: 230)
    static let statusMenuPassShot = CGSize(width: 330, height: 290)

    // MARK: - The hot key recorder

    /// Its corner, and how far a one-point line is drawn in from the edge so
    /// that it lands on whole pixels.
    static let recorderRadius: CGFloat = 6
    static let hairlineInset: CGFloat = 0.5

    // MARK: - The table of keys

    /// The sheet behind ⌘/, two columns wide, a row of it, and a key's cap.
    static var keySheetWidth: CGFloat { scaled(700) }
    static var keyRow: CGFloat { row(30) }
    static var keycap: CGFloat { scaled(22) }
    static var keycapRadius: CGFloat { scaled(5) }

    // MARK: - New Item

    /// The sheet behind ⌘N: its width, the field across its top, a tile and
    /// the mark on it.
    static var newItemWidth: CGFloat { scaled(580) }
    static var newItemField: CGFloat { scaled(48) }
    static var newItemTile: CGFloat { scaled(104) }
    static var newItemMark: CGFloat { scaled(44) }

    // MARK: - The generator

    /// The card, a row of its controls, and the box the password stands
    /// in, which is three lines of it tall whatever its length.
    static var generatorWidth: CGFloat { scaled(360) }
    static var generatorRow: CGFloat { row(34) }
    static var generatorPassword: CGFloat { scaled(72) }
    /// A switch, the knob in it and on a slider, a slider's track, and the
    /// room kept for the number at a slider's end.
    static var switchSize: CGSize { CGSize(width: scaled(32), height: scaled(19)) }
    static var knob: CGFloat { scaled(15) }
    static var sliderTrack: CGFloat { scaled(4) }
    static var sliderNumber: CGFloat { scaled(26) }

    // MARK: - Password Health

    /// The widest the page is laid out, in a window wider than that.
    static var dashboardWidth: CGFloat { scaled(940) }
    /// The strength bar, the gap between two of its segments, and the least
    /// a level with one password in it is given.
    static var strengthBar: CGFloat { scaled(14) }
    static var strengthGap: CGFloat { scaled(2) }
    static var strengthLeast: CGFloat { scaled(12) }
    /// A card's drawing, the line it is drawn with, and the row at the
    /// card's foot.
    static var watchDrawing: CGSize { CGSize(width: scaled(68), height: scaled(51)) }
    static var drawingLine: CGFloat { scaled(1.5) }
    static var cardFooter: CGFloat { row(40) }
    /// How many cards stand in a row.
    static let cardsAcross = 3

    // MARK: - Settings

    /// The settings window, which is one size, and the column its rooms are
    /// listed in.
    static let settingsWindow = CGSize(width: 760, height: 620)
    static let settingsSidebar: CGFloat = 200
    /// A row of a room, the widest a room's rows are laid out, a row of
    /// segments at a row's end, a recorder, and a field for a path.
    static var settingsRow: CGFloat { row(34) }
    /// The least there is over and under a row's control. A comfortable row
    /// has it already around a button or a row of segments, and a compact
    /// one, which is shorter than either, grows to keep it.
    static var settingsAir: CGFloat { scaled(3) }
    static var settingsColumn: CGFloat { scaled(520) }
    /// A segment with a span of time on it, one with a number, and one with
    /// a word.
    static var settingsSegment: CGFloat { scaled(62) }
    static var settingsNarrowSegment: CGFloat { scaled(40) }
    static var settingsWideSegment: CGFloat { scaled(96) }
    /// The four spans of a pass, with room left in the row for its label.
    static var settingsPassSpans: CGFloat { scaled(340) }
    static var recorder: CGSize { CGSize(width: scaled(132), height: scaled(24)) }
    static var settingsField: CGFloat { scaled(220) }
    /// The mark at the head of the About room.
    static var aboutMark: CGFloat { scaled(64) }

    // MARK: - Controls

    static var buttonHeight: CGFloat { scaled(28) }
    static var searchHeight: CGFloat { scaled(30) }
    static let focusRing: CGFloat = 3
    /// The ring around a sidebar row that would take what is held over it,
    /// and around the row the arrows are moving.
    static let dropRing: CGFloat = 2
}

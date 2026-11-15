import AppKit
import SwiftUI

/// The unlocked window (`docs/look.md`, "The window"): the sidebar under the
/// traffic lights, and beside it a toolbar over the item list and the
/// details. Hairlines divide the three and nothing else does.
struct PanesView: View {
    @ObservedObject var panes: Panes
    @ObservedObject private var store: VaultStore
    /// What the sidebar's foot says in a shot, whose store was never there.
    private let standing: SyncStanding?

    init(panes: Panes, standing: SyncStanding? = nil) {
        self.panes = panes
        self.standing = standing
        store = panes.store
    }

    var body: some View {
        GeometryReader { window in
            let layout = PaneLayout(width: window.size.width, wantsSidebar: panes.wantsSidebar)
            HStack(spacing: 0) {
                if layout.showsSidebar {
                    SidebarView(panes: panes, standing: standing)
                        .frame(width: layout.sidebar)
                        .transition(Motion.transition(.slide(.leading)))
                }
                VStack(spacing: 0) {
                    WindowToolbar(panes: panes, account: store.email, clearsTrafficLights: !layout.showsSidebar)
                    if panes.showsDashboard {
                        // Password Health's page has both columns, and the keys
                        // still have somewhere to land.
                        DashboardView(dashboard: panes.dashboard, show: panes.show)
                            .background(ListKeys(panes: panes, asked: panes.keysToList))
                    } else {
                        HStack(spacing: 0) {
                            ItemListView(panes: panes)
                                .frame(width: layout.list)
                            details
                                .frame(maxWidth: .infinity)
                                .overlay(alignment: .leading) { Hairline(.vertical, colour: Palette.divider) }
                        }
                    }
                }
                .background(Palette.content)
                .overlay(alignment: .leading) {
                    if layout.showsSidebar { Hairline(.vertical, colour: Palette.divider) }
                }
            }
            .animation(Motion.travel(Motion.slide), value: panes.wantsSidebar)
            .overlay {
                if let menu = panes.openMenu {
                    ListMenuLayer(panes: panes, menu: menu, layout: layout)
                }
            }
            .modifier(ItemLayers(panes: panes))
            .overlay { NewItemLayer(panes: panes) }
            .animation(Motion.animation(Motion.quick), value: panes.choosing != nil)
            .overlay { VaultLayer(panes: panes) }
            .animation(Motion.animation(Motion.quick), value: panes.naming != nil || panes.deletingVault != nil)
            .overlay { GeneratorLayer(panes: panes) }
            .animation(Motion.animation(Motion.quick), value: panes.generator?.purpose == .alone)
            .overlay { KeySheetLayer(panes: panes) }
            .animation(Motion.animation(Motion.quick), value: panes.showsKeys)
            // ← from the list has somewhere to go only while this is drawn.
            .onChange(of: layout.showsSidebar, initial: true) { _, isOut in
                panes.sidebarIsOut = isOut
                if !isOut, panes.focus == .sidebar { panes.focus = .list }
            }
        }
        .ignoresSafeArea()
    }

    /// The selected item, read, or the empty state when the list as it
    /// stands has no selected item in it.
    @ViewBuilder
    private var details: some View {
        if let editor = panes.editor {
            EditorView(panes: panes, editor: editor).id(editor.id)
        } else if let detail = panes.detail {
            // A new item starts at its top, whatever the last was scrolled to.
            ItemDetailView(panes: panes, detail: detail, strength: panes.strength,
                           banners: panes.banners).id(detail.id)
        } else {
            EmptyState(sentence: "No item selected", showsMark: true)
        }
    }
}

/// The sidebar's ground: the system's sidebar material, which takes a tint
/// from whatever is behind the window, under a veil of the palette's own
/// grey.
struct SidebarGround: View {
    var body: some View {
        SidebarMaterial()
            .overlay(Palette.sidebar.opacity(Palette.sidebarVeil))
    }
}

struct SidebarMaterial: NSViewRepresentable {
    var material = NSVisualEffectView.Material.sidebar
    /// A panel over another app is never in the active app's window, and
    /// would be drawn as a window that has been left.
    var state = NSVisualEffectView.State.followsWindowActiveState
    /// Corners, when the material is the whole of a window with no frame.
    /// A clip shape does not reach what is blended from behind the window.
    var radius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = state
        if radius > 0 { view.maskImage = Self.mask(radius) }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A rounded square that stretches from its middle point.
    private static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One point of `Palette.hairline`, along the edge it is laid on, or of
/// `Palette.divider` where the edge is between two columns.
struct Hairline: View {
    private let axis: Axis
    private let colour: Color

    init(_ axis: Axis, colour: Color = Palette.hairline) {
        self.axis = axis
        self.colour = colour
    }

    var body: some View {
        colour
            .frame(width: axis == .vertical ? Metrics.hairline : nil,
                   height: axis == .horizontal ? Metrics.hairline : nil)
    }
}

/// A column with nothing in it: a sentence in the middle, and in the details
/// the app's mark, faint, over it.
struct EmptyState: View {
    let sentence: String
    var showsMark = false

    var body: some View {
        VStack(spacing: Metrics.gap) {
            if showsMark {
                AppMark()
                    .fill(Palette.outline, style: AppMark.fill)
                    .frame(width: Metrics.emptyMark, height: Metrics.emptyMark)
                    .accessibilityHidden(true)
            }
            Text(sentence)
                .font(Fonts.sentence)
                .foregroundStyle(Palette.prompt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Surface {
    private static func window(_ name: String, width: CGFloat, height: CGFloat = Metrics.windowSize.height,
                               wantsSidebar: Bool = true) -> Surface {
        Surface(name: name, size: CGSize(width: width, height: height)) { store in
            let panes = Panes(store: store)
            panes.wantsSidebar = wantsSidebar
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The window with nothing in its columns, as it opens.
    static let emptyWindow = window("window-empty", width: Metrics.windowSize.width)

    /// The same at the narrowest that still holds three columns, at the
    /// window's own minimum, where the sidebar has folded, and with the
    /// sidebar folded by ⇧⌘D.
    static let windows: [Surface] = [
        emptyWindow,
        window("window-narrow", width: PaneLayout.narrowestWithSidebar),
        window("window-minimum", width: Metrics.windowMinimum.width, height: Metrics.windowMinimum.height),
        window("window-folded", width: Metrics.windowSize.width, wantsSidebar: false),
    ]
}

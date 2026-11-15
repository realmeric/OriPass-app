import SwiftUI

/// One thing the app draws, under the name its shots are filed by. The
/// builder is handed the demo vault, unlocked, and may throw: a surface that
/// cannot be built is reported by name and does not stop the others.
///
/// A card that draws adds its surface as a static here, beside the view it
/// builds or in an extension in that view's file, and adds it to `all`.
struct Surface {
    let name: String
    let size: CGSize
    /// Drawn with no window around it: a panel, which has no traffic lights
    /// and no toolbar.
    var isBare = false
    /// The window it is drawn in, when that is not the main one.
    var frame: (@MainActor () -> NSWindow)?
    /// The size it is drawn at, when that is not the actual one.
    var zoom = Zoom.actual
    /// Drawn with the breach check's switch on, which it is not for the
    /// rest (D13).
    var asksBreaches = false
    /// And with the list of sites that take a code.
    var asksTwoFactor = false
    let build: @MainActor (VaultStore) throws -> AnyView

    static var all: [Surface] { lockScreens + signInSheets + [.fingerOffer] + passwordQuestions + [.browserQuestion] + agentQuestions + passReports + autoFillSheets + windows + sidebars + syncFeet + lists + details + otherDetails + usernameWords + strengths + codeRows + fieldRows + histories + attachments + largeTypes + searches + itemMenus + vaultSheets + editors + otherEditors + newItems + generators + keys + quickAccesses + menuBars + healthSurfaces + banners + settings }
}

import AppKit

/// The app that was in front when the hot key fired: what Quick Access
/// suggests for, and where a login will be typed (OP-47). It is read before
/// the panel shows, because afterwards the answer may be this app.
struct FrontApp: Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String

    /// Nil when the app in front is this one, which has no login to offer
    /// itself.
    static func now() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return FrontApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                        name: app.localizedName ?? "")
    }

    var browser: Browser? { bundleID.flatMap(Browser.init(bundleID:)) }

    /// A browser whether or not its tab can be asked for. What is in front
    /// is then a page, and nothing about the app says which.
    var isBrowser: Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return Browser.known.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Apple's own: Finder, Terminal, Mail. `com.apple` names who made
    /// them and is not where any of them signs in.
    var isApples: Bool { bundleID?.lowercased().hasPrefix("com.apple.") == true }
}

extension FrontApp {
    /// The app the system's sheet is up over, read by the door when the
    /// provider asks (OP-80). Nothing says who is in front while a sheet is
    /// up: it may be the app, the provider's process or something of the
    /// system's, and OriPass itself when the vault was opened from its
    /// window with the sheet waiting. So the first of three that a person
    /// could be using: what is in front, what has the menu bar, and the
    /// owners of the windows on screen, front to back, which is the only
    /// one of them that a process holding the keys does not move.
    static func behindTheSheet() -> FrontApp? {
        let workspace = NSWorkspace.shared
        for app in [workspace.frontmostApplication, workspace.menuBarOwningApplication] {
            if let app, isSomeonesApp(app) { return FrontApp(app) }
        }
        return windowOwners().lazy.compactMap { NSRunningApplication(processIdentifier: $0) }
            .first(where: isSomeonesApp).map(FrontApp.init)
    }

    private init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
    }

    private static func isSomeonesApp(_ app: NSRunningApplication) -> Bool {
        isSomeonesApp(policy: app.activationPolicy, path: app.bundleURL, bundleID: app.bundleIdentifier,
                      pid: app.processIdentifier)
    }

    /// An app with a place in the Dock, which leaves out every agent and
    /// service. A running extension was `prohibited` on this Mac, and none of
    /// them had a sheet up, so its path is read as well. OriPass's own parts
    /// are never what the sheet is for.
    static func isSomeonesApp(policy: NSApplication.ActivationPolicy, path: URL?, bundleID: String?, pid: pid_t) -> Bool {
        policy == .regular && path?.pathExtension != "appex" && pid != ProcessInfo.processInfo.processIdentifier
            && bundleID?.hasPrefix(AppInfo.bundleID) != true
    }

    /// Who owns each ordinary window on screen, front to back. Reading an
    /// owner takes no permission, and a sheet of the system's stands on a
    /// higher level.
    private static func windowOwners() -> [pid_t] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer] as? Int == Int(CGWindowLevelForKey(.normalWindow)) else { return nil }
            return window[kCGWindowOwnerPID] as? pid_t
        }
    }
}

/// The browsers whose front tab can be asked for its address, each in the
/// words of its own scripting dictionary (`docs/notes.md`, "What is in
/// front"). These three are the ones on this Mac. Any other browser in
/// `known` is asked nothing and offered nothing.
enum Browser: CaseIterable {
    case safari, brave, orion

    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Safari": self = .safari
        case "com.brave.Browser": self = .brave
        case "com.kagi.kagimacOS": self = .orion
        default: return nil
        }
    }

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .brave: return "com.brave.Browser"
        case .orion: return "com.kagi.kagimacOS"
        }
    }

    var name: String {
        switch self {
        case .safari: return "Safari"
        case .brave: return "Brave"
        case .orion: return "Orion"
        }
    }

    /// Bundle ids of browsers, the three above among them, in lower case.
    /// A channel of one (`com.google.Chrome.canary`) has its id for a
    /// prefix; Firefox's are spelled out because they do not.
    static let known: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.brave.browser", "com.kagi.kagimacos",
        "com.google.chrome", "org.chromium.chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "com.microsoft.edgemac", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.duckduckgo.macos.browser", "app.zen-browser.zen",
        "org.torproject.torbrowser", "net.mullvad.mullvadbrowser", "org.mozilla.librewolf",
    ]

    /// What is asked for, as the object an Apple Event names.
    var tabAddress: NSAppleEventDescriptor {
        switch self {
        case .safari:
            // URL of document 1. A window that is not a browser's has no
            // document, and the first document is the page in front.
            return .property("pURL", of: .element("docu", 1))
        case .brave:
            // URL of active tab of window 1, Chromium's dictionary.
            return .property("URL ", of: .property("acTa", of: .element("cwin", 1)))
        case .orion:
            // URL of current tab of window 1. Orion's dictionary has
            // Safari's names for a tab and none of Chromium's.
            return .property("pURL", of: .property("cTab", of: .element("cwin", 1)))
        }
    }
}

/// Who is asked for the address of the tab in front. The app's is
/// `AppleEventTabs`; a test's and the tour's say what they were told to,
/// and no event leaves them.
protocol TabAsker {
    /// Nil when the app is no browser, has no page in front, will not say,
    /// or may not be asked.
    func address(of app: FrontApp) async -> String?
}

/// One Apple Event to the browser that was in front, by its pid, with a
/// second to answer in. The first one to each browser is where macOS asks
/// whether this app may control it, with the sentence under
/// `NSAppleEventsUsageDescription`; a no is remembered by the system and
/// comes back as an error at once, without a dialog. The event is sent off
/// the main thread, so neither the dialog nor a browser that is busy holds
/// the panel up.
struct AppleEventTabs: TabAsker {
    static let patience: TimeInterval = 1

    func address(of app: FrontApp) async -> String? {
        guard let browser = app.browser else { return nil }
        let event = Self.question(browser.tabAddress, to: app.pid)
        return await withCheckedContinuation { answered in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reply = try event.sendEvent(options: [.waitForReply, .neverInteract],
                                                    timeout: Self.patience)
                    answered.resume(returning: reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue)
                } catch {
                    // -1743 is a no to the system's question, -1712 a
                    // browser that did not answer in time.
                    Log.app.info("the tab in front was not read: \((error as NSError).code)")
                    answered.resume(returning: nil)
                }
            }
        }
    }

    /// "get" of one object, addressed to one process.
    static func question(_ object: NSAppleEventDescriptor, to pid: pid_t) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        return event
    }
}

extension NSAppleEventDescriptor {
    /// A four-letter code from a scripting dictionary.
    private static func code(_ letters: String) -> OSType {
        letters.utf8.reduce(0) { $0 << 8 | OSType($1) }
    }

    /// `property of container`, as an object specifier.
    static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: AEKeyword(typeProperty), form: AEKeyword(formPropertyID),
                  data: NSAppleEventDescriptor(typeCode: code(name)), from: container)
    }

    /// `class index` of the application.
    static func element(_ kind: String, _ index: Int32) -> NSAppleEventDescriptor {
        specifier(want: code(kind), form: AEKeyword(formAbsolutePosition),
                  data: NSAppleEventDescriptor(int32: index), from: .null())
    }

    private static func specifier(want: OSType, form: OSType, data: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }
}

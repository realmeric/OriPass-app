import BackgroundTasks
import SwiftUI

@main
struct OriPassApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        guard !Shared.isTesting else { return }
        // On the main queue: the handler is written in the App's init, so Swift 6 makes it
        // main-actor isolated and traps when BackgroundTasks calls it on a queue of its own.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundSync.identifier, using: .main) { task in
            let work = Task {
                let done = await BackgroundSync.run()
                task.setTaskCompleted(success: done)
            }
            task.expirationHandler = { work.cancel() }
            Self.scheduleSync()
        }
    }

    /// The next sync in the background, no sooner than fifteen minutes on.
    static func scheduleSync() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundSync.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Trace.note("the background sync was not scheduled: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    /// A Debug build's shots in dark: the headless simulator draws apps in
    /// light whatever `simctl ui appearance` says.
    static var look: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-OPDark") { return .dark }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            if Shared.isTesting {
                Color.clear
            } else {
                RootView(model: model)
                    .overlay {
                        // Over the vault whenever the app is not in front,
                        // so the app switcher's picture of it shows nothing.
                        if scenePhase != .active, case .open = model.phase { CoverView() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                        model.lockNow()
                    }
                    .preferredColorScheme(Self.look)
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        switch phase {
                        case .active: model.cameToFront()
                        case .background:
                            model.wentAway()
                            Self.scheduleSync()
                        default: break
                        }
                    }
            }
        }
    }
}

/// What the app switcher sees of an open vault.
struct CoverView: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .ignoresSafeArea()
    }
}

struct RootView: View {
    let model: AppModel
    @State private var copying = Copying()
    private var actions = QuickActions.shared

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        phase
            .sheet(isPresented: Binding(get: { actions.pending == .generate }, set: { if !$0 { actions.pending = nil } })) {
                GeneratorView(copying: copying)
            }
    }

    @ViewBuilder private var phase: some View {
        switch model.phase {
        case .signedOut:
            SignInView(model: model)
        case .locked(let account):
            LockView(model: model, account: account)
        case .open(let account):
            VaultView(model: model, account: account)
        }
    }
}

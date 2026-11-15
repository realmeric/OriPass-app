import SwiftUI

extension Surface {
    /// What the system's sheet says, each from the demo vault, with the
    /// system's own frame left out, which no shot can have.
    static var autoFillSheets: [Surface] {
        func sheet(_ name: String, holding isShown: @escaping (Login) -> Bool = { _ in true },
                   _ make: @escaping @MainActor ([SheetRow]) -> AutoFillSheet) -> Surface {
            Surface(name: "autofill-\(name)", size: Metrics.autoFillSheet, isBare: true) { store in
                let service = AutoFillService.page(url: "https://github.com/", name: "github.com")
                let rows = store.shelves.all.filter { $0.item.login.map(isShown) == true }.prefix(3).map {
                    SheetRow(id: $0.id, title: $0.item.name, username: $0.item.login?.username, service: service)
                }
                return AnyView(AutoFillSheetView(sheet: make(Array(rows))))
            }
        }
        return [
            sheet("list") { AutoFillSheet(still: .listed, name: "github.com", rows: $0) },
            sheet("passkeys", holding: { !$0.passkeysCreated.isEmpty }) {
                AutoFillSheet(still: .listed, name: "github.com", rows: $0, isForPasskeys: true)
            },
            sheet("codes", holding: { $0.totp != nil && !$0.passkeysCreated.isEmpty }) {
                AutoFillSheet(still: .listed, name: "github.com", rows: $0, isForCodes: true)
            },
            sheet("refused") {
                AutoFillSheet(still: .listed, name: "github.com", rows: $0,
                              refusal: "OriPass was not told to fill that login.")
            },
            sheet("nothing") { _ in AutoFillSheet(still: .nothing, name: "github.com") },
            sheet("unnamed") { _ in AutoFillSheet(still: .unnamed, name: nil, looksInFront: true) },
            sheet("found", holding: { $0.uris.contains { $0.uri.contains("git") } }) {
                AutoFillSheet(still: .listed, name: nil, rows: $0, looksInFront: true, word: "git")
            },
            sheet("locked") { _ in AutoFillSheet(still: .shut(isRunning: true), name: "github.com") },
            sheet("closed") { _ in AutoFillSheet(still: .shut(isRunning: false), name: "github.com") },
        ]
    }
}

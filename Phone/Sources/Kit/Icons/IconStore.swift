import UIKit

/// A site's icon from the account's icon server, kept as a file under
/// Caches named after the site, and asked for once per site at a time.
/// Asking tells that server which sites the vault has logins for, as
/// Bitwarden's own apps do (the Mac's D14).
actor IconStore {
    static let shared = IconStore()

    private var memory: [String: UIImage] = [:]
    private var asking: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "icons")
    }

    func icon(for host: String, server: Server) async -> UIImage? {
        if let image = memory[host] { return image }
        if let task = asking[host] { return await task.value }
        let task = Task<UIImage?, Never> { await self.load(host, server: server) }
        asking[host] = task
        let image = await task.value
        asking[host] = nil
        memory[host] = image
        return image
    }

    private func load(_ host: String, server: Server) async -> UIImage? {
        guard SiteHost.isValid(host), let folder = IconStore.folder else { return nil }
        let file = folder.appending(path: host + ".png")
        if let data = try? Data(contentsOf: file) { return UIImage(data: data) }
        let url = server.icons.appending(path: host).appending(path: "icon.png")
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// The files go with the account at sign-out.
    func forget() {
        memory = [:]
        if let folder = IconStore.folder { try? FileManager.default.removeItem(at: folder) }
    }
}

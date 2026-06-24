import DropboxKit
import UIKit

@MainActor
@Observable
final class DebugRunner {
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let step: String
        let message: String
        var isError: Bool = false
    }

    private(set) var entries: [LogEntry] = []
    private(set) var isRunning = false
    private var store: DropboxPhotoStore?

    func clear() {
        entries = []
        store = nil
    }

    func checkStatus(auth: DropboxAuthService) {
        let statusText: String
        switch auth.connectionStatus {
        case .notConnected:   statusText = "notConnected"
        case .authenticating: statusText = "authenticating"
        case .connected:      statusText = "connected"
        case .error(let msg): statusText = "error(\(msg))"
        }
        log(step: "check_status", "connectionStatus: \(statusText)")

        if let cred = auth.credential {
            log(step: "check_status", "accessToken: \(String(cred.accessToken.prefix(8)))...")
            log(step: "check_status", "refreshToken: \(cred.refreshToken != nil ? "present" : "none")")
            if let exp = cred.expiresAt {
                log(step: "check_status", "expiresAt: \(exp.formatted(.iso8601))")
            }
            if let acc = cred.accountId {
                log(step: "check_status", "accountId: \(acc)")
            }
        } else {
            log(step: "check_status", "no credential stored")
        }
    }

    func freshToken(auth: DropboxAuthService) async {
        log(step: "fresh_token", "requesting fresh access token...")
        do {
            let token = try await auth.freshAccessToken()
            log(step: "fresh_token", "ok: \(String(token.prefix(8)))...")
        } catch {
            log(step: "fresh_token", "\(error)", isError: true)
        }
    }

    func loadItems(auth: DropboxAuthService) async {
        log(step: "load_items", "creating DropboxPhotoStore...")
        let newStore = DropboxPhotoStore(auth: auth)
        log(step: "load_items", "calling loadItems()...")
        await newStore.loadItems()
        store = newStore

        switch newStore.loadStatus {
        case .loaded:
            log(step: "load_items", "loaded \(newStore.items.count) items")
        case .failed(let msg):
            log(step: "load_items", "failed: \(msg)", isError: true)
        default:
            break
        }
        if !newStore.debugInfo.isEmpty {
            log(step: "load_items", "debug: \(newStore.debugInfo)")
        }
    }

    func listItems() {
        guard let store else {
            log(step: "list_items", "store not loaded — run Load Items first", isError: true)
            return
        }
        if store.items.isEmpty {
            log(step: "list_items", "no items in store")
            return
        }
        let limit = min(store.items.count, 10)
        log(step: "list_items", "showing first \(limit) of \(store.items.count) items:")
        for item in store.items.prefix(10) {
            log(step: "list_items", "  \(item.path)")
        }
    }

    func getThumbnail() async {
        guard let store else {
            log(step: "get_thumbnail", "store not loaded — run Load Items first", isError: true)
            return
        }
        guard let item = store.items.first else {
            log(step: "get_thumbnail", "no items in store")
            return
        }
        log(step: "get_thumbnail", "fetching thumbnail for \(item.name)...")
        if let image = await store.thumbnail(for: item) {
            log(step: "get_thumbnail", "ok: \(Int(image.size.width))×\(Int(image.size.height)) pt")
        } else {
            log(step: "get_thumbnail", "returned nil", isError: true)
        }
    }

    func getFullImage() async {
        guard let store else {
            log(step: "get_full_image", "store not loaded — run Load Items first", isError: true)
            return
        }
        guard let item = store.items.first else {
            log(step: "get_full_image", "no items in store")
            return
        }
        log(step: "get_full_image", "fetching full image for \(item.name)...")
        if let image = await store.fullImage(for: item) {
            log(step: "get_full_image", "ok: \(Int(image.size.width))×\(Int(image.size.height)) pt")
        } else {
            log(step: "get_full_image", "returned nil", isError: true)
        }
    }

    func runAll(auth: DropboxAuthService) async {
        isRunning = true
        defer { isRunning = false }
        log(step: "run_all", "--- Run All started ---")
        checkStatus(auth: auth)
        await freshToken(auth: auth)
        await loadItems(auth: auth)
        listItems()
        await getThumbnail()
        await getFullImage()
        log(step: "run_all", "--- Run All completed ---")
    }

    // MARK: - Private

    private func log(step: String, _ message: String, isError: Bool = false) {
        entries.append(LogEntry(timestamp: Date(), step: step, message: message, isError: isError))
    }
}

import Foundation
import UIKit
import Observation

/// Manages the on-disk panorama library at `Documents/panoramas/` and publishes
/// the currently selected panorama. Callers keep `activeFilename` in sync with
/// `AppSettings.activePanoramaFilename`; the store reloads `activeImage` from
/// disk whenever the selection changes or the library is refreshed.
@MainActor
@Observable
final class PanoramaStore {
    static let shared = PanoramaStore()

    let directoryURL: URL

    private(set) var availableFilenames: [String] = []
    private(set) var activeFilename: String?
    private(set) var activeImage: UIImage?

    var activeURL: URL? {
        activeFilename.map { directoryURL.appendingPathComponent($0) }
    }

    init(directoryURL: URL = PanoramaStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
        ensureDirectoryExists()
        refresh()
    }

    static func defaultDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("panoramas", isDirectory: true)
    }

    /// Re-scan the panoramas directory and refresh `availableFilenames`. Also
    /// reloads `activeImage` from disk so removing the active file from outside
    /// the app clears it.
    func refresh() {
        ensureDirectoryExists()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        availableFilenames = contents
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { $0.lastPathComponent }
            .sorted()
        reloadActiveImage()
    }

    /// Write PNG bytes into the panoramas directory and return the on-disk
    /// filename. Generates a UUID-named file when `filename` is nil.
    @discardableResult
    func save(pngBytes: Data, filename: String? = nil) throws -> String {
        ensureDirectoryExists()
        let name = filename ?? "\(UUID().uuidString).png"
        let url = directoryURL.appendingPathComponent(name)
        try pngBytes.write(to: url, options: .atomic)
        refresh()
        return name
    }

    /// Delete a panorama PNG. If it was the active panorama, clears the
    /// selection as well.
    func delete(filename: String) throws {
        let url = directoryURL.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: url)
        if activeFilename == filename {
            activeFilename = nil
        }
        refresh()
    }

    /// Select (or clear) the active panorama. `activeImage` is loaded from disk
    /// synchronously; if the file is missing or unreadable, `activeImage` is
    /// nil while `activeFilename` still reflects the caller's request so a
    /// later `refresh()` (after the file appears) can resolve it.
    func setActive(filename: String?) {
        guard activeFilename != filename else { return }
        activeFilename = filename
        reloadActiveImage()
    }

    func url(for filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func reloadActiveImage() {
        guard let name = activeFilename else {
            activeImage = nil
            return
        }
        let url = directoryURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            activeImage = nil
            return
        }
        activeImage = image
    }
}

import XCTest
import UIKit
@testable import vmux

@MainActor
final class PanoramaStoreTests: XCTestCase {

    func testInitCreatesDirectoryAndStartsEmpty() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: env.tempDir.path))
        XCTAssertEqual(env.store.availableFilenames, [])
        XCTAssertNil(env.store.activeImage)
        XCTAssertNil(env.store.activeFilename)
        XCTAssertNil(env.store.activeURL)
    }

    func testRefreshListsOnlyPNGsAlphabetically() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        try png.write(to: env.tempDir.appendingPathComponent("beta.png"))
        try png.write(to: env.tempDir.appendingPathComponent("alpha.png"))
        try Data("not a png".utf8).write(to: env.tempDir.appendingPathComponent("readme.txt"))
        try png.write(to: env.tempDir.appendingPathComponent("photo.jpg"))

        env.store.refresh()

        XCTAssertEqual(env.store.availableFilenames, ["alpha.png", "beta.png"])
    }

    func testSaveWritesBytesAndUpdatesList() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let name = try env.store.save(pngBytes: png)
        XCTAssertTrue(name.hasSuffix(".png"))

        let written = try Data(contentsOf: env.tempDir.appendingPathComponent(name))
        XCTAssertEqual(written, png)
        XCTAssertTrue(env.store.availableFilenames.contains(name))
    }

    func testSaveWithExplicitFilename() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let name = try env.store.save(pngBytes: png, filename: "named.png")
        XCTAssertEqual(name, "named.png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: env.tempDir.appendingPathComponent("named.png").path
        ))
    }

    func testSetActiveLoadsImageFromDisk() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData(width: 4, height: 4)
        let name = try env.store.save(pngBytes: png)
        XCTAssertNil(env.store.activeImage)

        env.store.setActive(filename: name)

        XCTAssertEqual(env.store.activeFilename, name)
        XCTAssertNotNil(env.store.activeImage)
        XCTAssertEqual(env.store.activeURL, env.tempDir.appendingPathComponent(name))
    }

    func testSetActiveNilClearsImage() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let name = try env.store.save(pngBytes: png)
        env.store.setActive(filename: name)
        XCTAssertNotNil(env.store.activeImage)

        env.store.setActive(filename: nil)

        XCTAssertNil(env.store.activeFilename)
        XCTAssertNil(env.store.activeImage)
        XCTAssertNil(env.store.activeURL)
    }

    func testSetActiveToMissingFilenameLeavesImageNil() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        env.store.setActive(filename: "does-not-exist.png")

        XCTAssertEqual(env.store.activeFilename, "does-not-exist.png")
        XCTAssertNil(env.store.activeImage)
    }

    func testDeleteRemovesFileAndClearsActiveWhenMatched() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let name = try env.store.save(pngBytes: png)
        env.store.setActive(filename: name)
        XCTAssertNotNil(env.store.activeImage)

        try env.store.delete(filename: name)

        XCTAssertFalse(env.store.availableFilenames.contains(name))
        XCTAssertNil(env.store.activeFilename)
        XCTAssertNil(env.store.activeImage)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: env.tempDir.appendingPathComponent(name).path
        ))
    }

    func testDeleteOtherFileKeepsActiveSelection() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let active = try env.store.save(pngBytes: png)
        let other = try env.store.save(pngBytes: png)
        env.store.setActive(filename: active)

        try env.store.delete(filename: other)

        XCTAssertEqual(env.store.activeFilename, active)
        XCTAssertNotNil(env.store.activeImage)
    }

    func testRefreshClearsActiveImageWhenFileRemovedExternally() throws {
        let env = makeEnv()
        defer { cleanup(env) }

        let png = try makePNGData()
        let name = try env.store.save(pngBytes: png)
        env.store.setActive(filename: name)
        XCTAssertNotNil(env.store.activeImage)

        try FileManager.default.removeItem(at: env.tempDir.appendingPathComponent(name))
        env.store.refresh()

        XCTAssertNil(env.store.activeImage)
        XCTAssertEqual(env.store.activeFilename, name)
    }

    // MARK: - Helpers

    private struct Env {
        let tempDir: URL
        let store: PanoramaStore
    }

    private func makeEnv() -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmux-panorama-tests-\(UUID().uuidString)", isDirectory: true)
        return Env(tempDir: dir, store: PanoramaStore(directoryURL: dir))
    }

    private func cleanup(_ env: Env) {
        try? FileManager.default.removeItem(at: env.tempDir)
    }

    private func makePNGData(width: CGFloat = 2, height: CGFloat = 2) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let data = image.pngData() else {
            throw NSError(
                domain: "PanoramaStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
            )
        }
        return data
    }
}

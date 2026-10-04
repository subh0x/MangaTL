import Foundation
import Testing
@testable import MangaTLCore

@Suite struct ProjectTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    @Test func newProjectListsImagesInNaturalOrderAndPersists() throws {
        let project = try ProjectSource(folder: fixture.folder)
        #expect(project.pages.map(\.file) == Fixture.names)
        #expect(FileManager.default.fileExists(atPath: project.projectFileURL.path))
        project.state = { var s = ProjectFile.State(); s.page = 2; s.mode = "reader"; return s }()
        var settings = project.settings
        settings.language = .korean
        project.settings = settings

        let reopened = try ProjectSource(folder: fixture.folder)
        #expect(reopened.pages == project.pages, "page ids are stable across opens")
        #expect(reopened.state.page == 2 && reopened.state.mode == "reader")
        #expect(reopened.settings.language == .korean)
    }

    @Test func reconcileAppendsNewFilesAndDropsMissingOnes() throws {
        let first = try ProjectSource(folder: fixture.folder)
        let keptID = first.pageKey(at: 0)
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("p2.jpg"))
        try Fixture.writeJPEG(size: CGSize(width: 800, height: 1200), to: fixture.folder.appendingPathComponent("p11.jpg"))
        let reopened = try ProjectSource(folder: fixture.folder)
        #expect(reopened.pages.map(\.file) == ["p1.jpg", "p10.jpg", "p11.jpg"])
        #expect(reopened.pageKey(at: 0) == keptID)
    }

    @Test func reorderingKeepsEachPagesTranslation() throws {
        let project = try ProjectSource(folder: fixture.folder)
        let ids = project.pages.map(\.id)
        var doc = PageDoc(workingSize: CGSize(width: 10, height: 10))
        doc.blocks = [TextBlock(textRect: .zero, layoutRect: .zero, shape: .rectangle, sourceText: "", translation: "third page")]
        try project.store.save(doc, page: ids[2])

        project.move(fromOffsets: [2], toOffset: 0)
        #expect(project.pages.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(project.store.loadPage(project.pageKey(at: 0))?.blocks.first?.translation == "third page")

        project.move(fromOffsets: [0], toOffset: 3)
        #expect(project.pages.map(\.id) == ids)
        let reopened = try ProjectSource(folder: fixture.folder)
        #expect(reopened.pages.map(\.id) == ids)
    }

    @Test func insertCopiesImagesInAndRemoveKeepsFiles() throws {
        let project = try ProjectSource(folder: fixture.folder)
        let outside = fixture.root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Fixture.writeJPEG(size: CGSize(width: 600, height: 900), to: outside.appendingPathComponent("p1.jpg"))
        let added = try project.insert(files: [outside.appendingPathComponent("p1.jpg")], at: 1)
        #expect(added.map(\.file) == ["p1 2.jpg"], "name clash gets a suffix")
        #expect(project.pages.map(\.file) == ["p1.jpg", "p1 2.jpg", "p2.jpg", "p10.jpg"])
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("p1 2.jpg").path))

        project.remove(atOffsets: [1])
        #expect(project.count == 3)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("p1 2.jpg").path))
        // A removed page stays out on reopen? No: files in the folder are reconciled back in.
        #expect(try ProjectSource(folder: fixture.folder).count == 4)
    }

    @Test func importsWorkFromThePreProjectStore() throws {
        let legacy = ProjectStore.legacyDirectory(forSourceID: PageSources.identity(of: fixture.folder.standardizedFileURL))
        defer { try? FileManager.default.removeItem(at: legacy) }
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("patches"), withIntermediateDirectories: true)
        var doc = PageDoc(workingSize: CGSize(width: 10, height: 10))
        doc.blocks = [TextBlock(textRect: .zero, layoutRect: .zero, shape: .rectangle, sourceText: "", translation: "old work")]
        try JSONEncoder().encode(doc).write(to: legacy.appendingPathComponent("pages/1.json"))
        try JSONEncoder().encode(ProjectSettings(language: .french)).write(to: legacy.appendingPathComponent("project.json"))

        let project = try ProjectSource(folder: fixture.folder)
        #expect(project.store.loadPage(project.pageKey(at: 1))?.blocks.first?.translation == "old work")
        #expect(project.settings.language == .french)
        #expect(project.store.loadPage(project.pageKey(at: 0)) == nil)
    }

    @Test func importingACBZWritesAnOrderedFolder() async throws {
        let out = fixture.root.appendingPathComponent("Imported")
        try await BookExporter.export(try PageSources.open(fixture.cbz), store: nil, settings: ProjectSettings(), to: out, format: .folder)
        let project = try ProjectSource(folder: out)
        #expect(project.pages.map(\.file) == ["1.jpg", "2.jpg", "3.jpg"])
    }
}

@Suite struct HexColorTests {
    @Test(arguments: ["#1E90FF", "1e90ff", " #1E90FF "])
    func parsesSixDigits(_ text: String) {
        #expect(RGBA(hex: text)?.hex == "#1E90FF")
    }

    @Test func expandsThreeDigits() {
        #expect(RGBA(hex: "#fa0")?.hex == "#FFAA00")
    }

    @Test(arguments: ["", "#12345", "#GGGGGG", "red", "#1234567"])
    func rejectsInvalid(_ text: String) {
        #expect(RGBA(hex: text) == nil)
    }

    @Test func roundTripsExistingColours() {
        #expect(RGBA.white.hex == "#FFFFFF" && RGBA.black.hex == "#000000")
    }
}

@Suite struct ProjectOpenFailureTests {
    @Test func missingFolderIsNotCreated() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mangatl-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try ProjectSource(folder: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}

@Suite struct ZoomAndThumbnailTierTests {
    @Test func zoomStateRoundTrips() throws {
        let fixture = try Fixture()
        let project = try ProjectSource(folder: fixture.folder)
        var state = ProjectFile.State()
        state.mode = "reader"
        state.zoom = 1350
        project.state = state
        #expect(try ProjectSource(folder: fixture.folder).state.zoom == 1350)
        state.zoom = nil
        state.fit = "height"
        project.state = state
        let reopened = try ProjectSource(folder: fixture.folder).state
        #expect(reopened.fit == "height" && reopened.zoom == nil)
        // Files written before zoom existed still load.
        let old = #"{"page":3,"mode":"grid"}"#
        let decoded = try JSONDecoder().decode(ProjectFile.State.self, from: Data(old.utf8))
        #expect(decoded.page == 3 && decoded.zoom == nil && decoded.fit == nil)
    }

    @Test func largeThumbnailsAreASeparateTier() throws {
        let fixture = try Fixture()
        let source = try ProjectSource(folder: fixture.folder)
        let root = fixture.root.appendingPathComponent("thumbs")
        let cache = ThumbnailCache(source: source, root: root)
        let small = try cache.load(0)
        let large = try cache.load(0, large: true)
        #expect(max(small.width, small.height) == ThumbnailCache.maxPixelSize)
        #expect(max(large.width, large.height) == ThumbnailCache.largePixelSize)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".heic") }
        #expect(files.count == 2)
    }
}

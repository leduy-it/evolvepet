import AppKit
import XCTest
@testable import agentpet

/// Upstream, a pet's artwork never changes: `stageIndex` only styles a rank badge.
/// These tests pin the behaviour that makes it actually evolve — and, just as
/// importantly, that a pet WITHOUT stages still behaves exactly as it did before.
final class PetEvolutionTests: XCTestCase {

    // MARK: - helpers

    /// A spritesheet with one row of `frames` cells, each a solid colour block
    /// separated by transparent gutters so `SpriteSlicer` can find them.
    private func sheet(frames: Int, colour: NSColor) -> Data {
        let cell = 32, gutter = 8
        let w = frames * cell + (frames - 1) * gutter
        let img = NSImage(size: NSSize(width: w, height: cell))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: w, height: cell).fill()
        colour.setFill()
        for i in 0..<frames {
            NSRect(x: CGFloat(i * (cell + gutter)), y: 0, width: CGFloat(cell), height: CGFloat(cell)).fill()
        }
        img.unlockFocus()
        var r = CGRect(origin: .zero, size: img.size)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])!
    }

    private func makePack(_ json: String, sheets: [String: Data]) throws -> ImagePetPack? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evolvepet-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("pet.json"))
        for (name, data) in sheets {
            try data.write(to: dir.appendingPathComponent(name))
        }
        return SpriteSlicer.loadPack(directory: dir)
    }

    // MARK: - backwards compatibility

    /// Every pet published so far has no `stages`. It must load and render as before.
    func testPetWithoutStagesStillWorks() throws {
        let pack = try makePack("""
        { "id": "legacy", "displayName": "Legacy", "spritesheetPath": "sheet.png" }
        """, sheets: ["sheet.png": sheet(frames: 3, colour: .red)])

        let p = try XCTUnwrap(pack)
        XCTAssertEqual(p.stages.count, 1, "a stage-less pet should get exactly one implicit stage")
        XCTAssertFalse(p.evolves)
        XCTAssertFalse(p.clips.isEmpty, "`clips` must still return frames for old call sites")
        // The sprite must not change with level — there is nothing to evolve into.
        XCTAssertEqual(p.clip(0, level: 0).count, p.clip(0, level: 99).count)
    }

    // MARK: - evolution

    func testSpriteChangesWhenTheLevelCrossesAStageThreshold() throws {
        // stage 1: 2 frames. stage 2 (from level 10): 5 frames. Different frame
        // counts make "did the artwork actually change?" unambiguous.
        let pack = try makePack("""
        {
          "id": "volt", "displayName": "Volt", "spritesheetPath": "stage-1.png",
          "stages": [
            { "minLevel": 0,  "name": "Volt",    "spritesheetPath": "stage-1.png" },
            { "minLevel": 10, "name": "Voltarc", "spritesheetPath": "stage-2.png" }
          ]
        }
        """, sheets: [
            "stage-1.png": sheet(frames: 2, colour: .yellow),
            "stage-2.png": sheet(frames: 5, colour: .blue),
        ])

        let p = try XCTUnwrap(pack)
        XCTAssertTrue(p.evolves)
        XCTAssertEqual(p.stages.count, 2)

        // Below the threshold -> stage 1.
        XCTAssertEqual(p.clip(0, level: 0).count, 2)
        XCTAssertEqual(p.clip(0, level: 9).count, 2)
        XCTAssertEqual(p.stage(forLevel: 9)?.name, "Volt")
        XCTAssertEqual(p.stageIndex(forLevel: 9), 0)

        // At and above it -> stage 2. THIS is the bug we are fixing: upstream this
        // would still return stage 1's frames.
        XCTAssertEqual(p.clip(0, level: 10).count, 5, "the pet must render its evolved sheet")
        XCTAssertEqual(p.clip(0, level: 40).count, 5)
        XCTAssertEqual(p.stage(forLevel: 10)?.name, "Voltarc")
        XCTAssertEqual(p.stageIndex(forLevel: 10), 1)
    }

    func testNextEvolutionLevel() throws {
        let pack = try makePack("""
        {
          "id": "volt", "displayName": "Volt", "spritesheetPath": "stage-1.png",
          "stages": [
            { "minLevel": 0,  "spritesheetPath": "stage-1.png" },
            { "minLevel": 10, "spritesheetPath": "stage-2.png" }
          ]
        }
        """, sheets: [
            "stage-1.png": sheet(frames: 2, colour: .yellow),
            "stage-2.png": sheet(frames: 5, colour: .blue),
        ])
        let p = try XCTUnwrap(pack)
        XCTAssertEqual(p.nextEvolutionLevel(after: 0), 10)
        XCTAssertEqual(p.nextEvolutionLevel(after: 9), 10)
        XCTAssertNil(p.nextEvolutionLevel(after: 10), "nothing left to evolve into")
    }

    /// A stage whose sheet is missing must not take the whole pet down with it.
    func testMissingStageSheetDegradesGracefully() throws {
        let pack = try makePack("""
        {
          "id": "volt", "displayName": "Volt", "spritesheetPath": "stage-1.png",
          "stages": [
            { "minLevel": 0,  "spritesheetPath": "stage-1.png" },
            { "minLevel": 10, "spritesheetPath": "does-not-exist.png" }
          ]
        }
        """, sheets: ["stage-1.png": sheet(frames: 2, colour: .yellow)])

        let p = try XCTUnwrap(pack, "a broken stage must not make the pet unloadable")
        XCTAssertEqual(p.stages.count, 1)
        XCTAssertEqual(p.clip(0, level: 99).count, 2, "falls back to the stage it does have")
    }

    func testAttributesDecode() throws {
        let pack = try makePack("""
        {
          "id": "volt", "displayName": "Volt", "spritesheetPath": "sheet.png",
          "attributes": { "type": "electric", "hp": 42, "atk": 61, "def": 38, "spd": 74 }
        }
        """, sheets: ["sheet.png": sheet(frames: 2, colour: .yellow)])

        let a = try XCTUnwrap(try XCTUnwrap(pack).attributes)
        XCTAssertEqual(a.type, "electric")
        XCTAssertEqual(a.atk, 61)
        XCTAssertEqual(a.spd, 74)
    }

    /// Evolving should make the pet stronger, not merely different — so stats are
    /// per-stage, and the stats shown must be the ones for the form it has reached.
    func testPerStageAttributesAndName() throws {
        let pack = try makePack("""
        {
          "id": "volt", "displayName": "Volt", "spritesheetPath": "stage-1.png",
          "stages": [
            { "minLevel": 0,  "name": "Volt",    "spritesheetPath": "stage-1.png",
              "attributes": { "type": "electric", "hp": 50, "atk": 58, "def": 46, "spd": 48 } },
            { "minLevel": 10, "name": "Anodane", "spritesheetPath": "stage-2.png",
              "attributes": { "type": "electric", "hp": 68, "atk": 90, "def": 62, "spd": 65 } }
          ]
        }
        """, sheets: [
            "stage-1.png": sheet(frames: 2, colour: .yellow),
            "stage-2.png": sheet(frames: 5, colour: .blue),
        ])

        let p = try XCTUnwrap(pack)
        XCTAssertEqual(p.attributes(forLevel: 9)?.atk, 58)
        XCTAssertEqual(p.attributes(forLevel: 10)?.atk, 90, "the evolved form must be stronger")
        XCTAssertEqual(p.attributes(forLevel: 10)?.type, "electric")

        // This is what the notification says: "Volt evolved into Anodane!"
        XCTAssertEqual(p.name(forLevel: 9), "Volt")
        XCTAssertEqual(p.name(forLevel: 10), "Anodane")
    }

    /// A stage may declare no attributes of its own; it should inherit the pack's.
    func testStageWithoutAttributesInheritsThePack() throws {
        let pack = try makePack("""
        {
          "id": "x", "displayName": "X", "spritesheetPath": "s1.png",
          "attributes": { "type": "rock", "hp": 40, "atk": 40, "def": 40, "spd": 40 },
          "stages": [
            { "minLevel": 0,  "spritesheetPath": "s1.png" },
            { "minLevel": 10, "spritesheetPath": "s2.png" }
          ]
        }
        """, sheets: [
            "s1.png": sheet(frames: 2, colour: .gray),
            "s2.png": sheet(frames: 5, colour: .brown),
        ])

        let p = try XCTUnwrap(pack)
        XCTAssertEqual(p.attributes(forLevel: 0)?.type, "rock")
        XCTAssertEqual(p.attributes(forLevel: 10)?.type, "rock")
    }

    /// Stage order in the file must not matter.
    func testStagesAreSortedByLevel() throws {
        let pack = try makePack("""
        {
          "id": "x", "displayName": "X", "spritesheetPath": "s2.png",
          "stages": [
            { "minLevel": 10, "name": "Second", "spritesheetPath": "s2.png" },
            { "minLevel": 0,  "name": "First",  "spritesheetPath": "s1.png" }
          ]
        }
        """, sheets: [
            "s1.png": sheet(frames: 2, colour: .yellow),
            "s2.png": sheet(frames: 5, colour: .blue),
        ])

        let p = try XCTUnwrap(pack)
        XCTAssertEqual(p.name(forLevel: 0), "First")
        XCTAssertEqual(p.name(forLevel: 10), "Second")
        XCTAssertEqual(p.clip(0, level: 0).count, 2)
    }
}

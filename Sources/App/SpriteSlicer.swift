import AppKit

/// One evolution stage of a pet: its own spritesheet, unlocked at `minLevel`.
///
/// Upstream, a pet's artwork never changes — `stageIndex` only styles a rank
/// badge (see `StageBadge`). A stage here carries real frames, so the pet
/// visibly transforms as it levels.
struct PetStage {
    let minLevel: Int
    let name: String?
    let clips: [[NSImage]]
}

/// A pet pack backed by a spritesheet (pet.json + image), e.g. the Codex/petdex
/// pet format. Sliced at load time into clips (one per sheet row); each clip is
/// a separate animation the user can bind to a state.
///
/// A pack may declare several evolution `stages`. Packs without them have a
/// single stage, so every existing call site keeps working unchanged.
struct ImagePetPack: Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let stages: [PetStage]
    let attributes: PetAttributes?
    let directory: URL

    /// The first stage's clips. Kept so callers that predate evolution — and
    /// any pet without stages — behave exactly as before.
    var clips: [[NSImage]] { stages.first?.clips ?? [] }
    var clipCount: Int { clips.count }

    func clip(_ index: Int) -> [NSImage] { clip(index, level: 0) }

    /// The highest stage the pet has reached at `level`.
    func stage(forLevel level: Int) -> PetStage? {
        stages.last { level >= $0.minLevel } ?? stages.first
    }

    /// The stage's index, for badges and evolution checks.
    func stageIndex(forLevel level: Int) -> Int {
        guard let s = stage(forLevel: level) else { return 0 }
        return stages.firstIndex { $0.minLevel == s.minLevel } ?? 0
    }

    /// A clip at the pet's *current* evolution stage.
    func clip(_ index: Int, level: Int) -> [NSImage] {
        let frames = stage(forLevel: level)?.clips ?? []
        guard !frames.isEmpty else { return [] }
        return frames[min(max(index, 0), frames.count - 1)]
    }

    /// Whether this pack actually evolves (more than one stage).
    var evolves: Bool { stages.count > 1 }

    /// The level at which the next evolution happens, if any.
    func nextEvolutionLevel(after level: Int) -> Int? {
        stages.first { $0.minLevel > level }?.minLevel
    }
}

/// Battle-style attributes, shown in the stats view. Optional: a pet without
/// them simply shows none.
struct PetAttributes: Decodable, Equatable {
    let type: String?
    let hp: Int?
    let atk: Int?
    let def: Int?
    let spd: Int?
}

private struct StageManifest: Decodable {
    let minLevel: Int
    let name: String?
    let spritesheetPath: String
}

private struct PetManifest: Decodable {
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String
    /// Optional evolution stages. Absent in every pet published so far, which is
    /// why `spritesheetPath` remains the source of truth for stage one.
    let stages: [StageManifest]?
    let attributes: PetAttributes?
}

/// Loads a spritesheet pet pack and slices its frames by detecting the
/// transparent gutters between cells, so no grid metadata is required.
enum SpriteSlicer {
    /// Reads only the pack id from a directory's manifest, without slicing the
    /// spritesheet. Lets the store pick the prioritised pack to load first.
    static func manifestID(directory: URL) -> String? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data)
        else { return nil }
        return manifest.id
    }

    static func loadPack(directory: URL) -> ImagePetPack? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data)
        else { return nil }

        // Stage one is always `spritesheetPath`, so a pet that declares no stages
        // — i.e. every pet published to date — loads exactly as it did before.
        var stages: [PetStage] = []
        if let declared = manifest.stages, !declared.isEmpty {
            for s in declared.sorted(by: { $0.minLevel < $1.minLevel }) {
                guard let clips = sliceSheet(directory.appendingPathComponent(s.spritesheetPath))
                else { continue }   // a missing stage sheet must not kill the pet
                stages.append(PetStage(minLevel: s.minLevel, name: s.name, clips: clips))
            }
        }
        if stages.isEmpty {
            guard let clips = sliceSheet(directory.appendingPathComponent(manifest.spritesheetPath))
            else { return nil }
            stages = [PetStage(minLevel: 0, name: manifest.displayName, clips: clips)]
        }

        return ImagePetPack(id: manifest.id,
                            displayName: manifest.displayName,
                            description: manifest.description,
                            stages: stages,
                            attributes: manifest.attributes,
                            directory: directory)
    }

    /// Loads one spritesheet and slices it into clips (one per row).
    private static func sliceSheet(_ url: URL) -> [[NSImage]]? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let clips = slice(cg).map { row in
            row.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        return clips.isEmpty ? nil : clips
    }

    /// Slices a spritesheet into clips (one per sheet row) using alpha gutter
    /// detection, so no grid metadata is required. Columns are detected within
    /// each row, so ragged sheets (rows with different frame counts or unaligned
    /// columns, e.g. AI-generated sheets) slice correctly. Uniform grids are
    /// unaffected: every row finds the same columns.
    static func slice(_ image: CGImage, alphaThreshold: UInt8 = 16) -> [[CGImage]] {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let data = pixelData(image, width: w, height: h) else { return [] }

        var rowHas = [Bool](repeating: false, count: h)
        data.withUnsafeBufferPointer { buf in
            for y in 0..<h {
                let rowStart = y * w * 4
                for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                    rowHas[y] = true
                    break
                }
            }
        }
        let rowBands = segments(rowHas)
        guard !rowBands.isEmpty else { return [] }

        var clips: [[CGImage]] = []
        data.withUnsafeBufferPointer { buf in
            for row in rowBands {
                var colHas = [Bool](repeating: false, count: w)
                for y in row.lower..<row.upper {
                    let rowStart = y * w * 4
                    for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                        colHas[x] = true
                    }
                }
                var clip: [CGImage] = []
                for col in segments(colHas) {
                    let rect = CGRect(x: col.lower, y: row.lower,
                                      width: col.upper - col.lower, height: row.upper - row.lower)
                    guard let cropped = image.cropping(to: rect) else { continue }
                    let fw = Int(rect.width), fh = Int(rect.height)
                    let space = CGColorSpaceCreateDeviceRGB()
                    let info = CGImageAlphaInfo.premultipliedLast.rawValue
                    guard let ctx = CGContext(data: nil, width: fw, height: fh,
                                             bitsPerComponent: 8, bytesPerRow: fw * 4,
                                             space: space, bitmapInfo: info) else { continue }
                    ctx.draw(cropped, in: CGRect(origin: .zero, size: CGSize(width: fw, height: fh)))
                    guard let frame = ctx.makeImage() else { continue }
                    clip.append(frame)
                }
                if !clip.isEmpty { clips.append(clip) }
            }
        }
        return clips
    }

    private static func pixelData(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = data.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(data: ptr.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private static func segments(_ occupancy: [Bool]) -> [(lower: Int, upper: Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for (i, filled) in occupancy.enumerated() {
            if filled, start == nil { start = i }
            else if !filled, let s = start { result.append((s, i)); start = nil }
        }
        if let s = start { result.append((s, occupancy.count)) }
        return result
    }
}

import Foundation

struct PetEntry {
    let id: String
    let displayName: String
    let spritesheetPath: String
    let version: Int // 1 or 2
    let rows: Int    // 9 or 11
}

enum PetCatalog {
    private static let petsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/pets")

    static func scan() -> [PetEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: petsDir.path) else { return [] }

        return dirs.compactMap { dir in
            let petDir = petsDir.appendingPathComponent(dir)
            let manifestPath = petDir.appendingPathComponent("pet.json").path
            guard let data = fm.contents(atPath: manifestPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let spritesheetFile = json["spritesheetPath"] as? String ?? "spritesheet.webp"
            let spritesheetPath = petDir.appendingPathComponent(spritesheetFile).path
            guard let version = detectVersion(path: spritesheetPath) else { return nil }

            return PetEntry(
                id: json["id"] as? String ?? dir,
                displayName: json["displayName"] as? String ?? dir,
                spritesheetPath: spritesheetPath,
                version: version,
                rows: version == 2 ? 11 : 9
            )
        }
    }

    // Detect v1/v2 by reading WebP header for image height.
    private static func detectVersion(path: String) -> Int? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let header = fh.readData(ofLength: 30)
        guard header.count >= 30 else { return nil }

        let riff = String(data: header[0..<4], encoding: .ascii)
        let webp = String(data: header[8..<12], encoding: .ascii)
        guard riff == "RIFF", webp == "WEBP" else { return nil }

        let chunk = String(data: header[12..<16], encoding: .ascii)
        let height: Int

        switch chunk {
        case "VP8 ":
            // Lossy: 14-bit height at bytes 28-29
            height = Int(header[28]) | (Int(header[29]) << 8)
            let masked = height & 0x3FFF
            return masked == 2288 ? 2 : masked == 1872 ? 1 : nil
        case "VP8L":
            // Lossless: bits 14-27 of uint32 at offset 21
            let bits = UInt32(header[21]) | (UInt32(header[22]) << 8) |
                       (UInt32(header[23]) << 16) | (UInt32(header[24]) << 24)
            height = Int((bits >> 14) & 0x3FFF) + 1
        case "VP8X":
            // Extended: 24-bit height at offset 27 (+1)
            height = Int(header[27]) | (Int(header[28]) << 8) | (Int(header[29]) << 16)
            let h = height + 1
            return h == 2288 ? 2 : h == 1872 ? 1 : nil
        default:
            return nil
        }

        return height == 2288 ? 2 : height == 1872 ? 1 : nil
    }
}

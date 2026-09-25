import XCTest
@testable import Yoob
@testable import YoobRealistic

/// The SDK's per-character lip timing and the manifest fields that carry it (0.6.0).
final class RuntimeTuningTests: XCTestCase {
    func testMeasuredLeadsAndInstantSettings() {
        XCTAssertEqual(FaceTuning.leadMilliseconds(identity: FaceTuning.lunaIdentity), 83)
        XCTAssertEqual(FaceTuning.leadMilliseconds(identity: FaceTuning.animeIdentity), 46)
        XCTAssertEqual(FaceTuning.leadMilliseconds(identity: "another-model"), 0)
        XCTAssertEqual(FaceTuning.articulationGain(identity: FaceTuning.lunaIdentity), 1.2)
        XCTAssertEqual(FaceTuning.articulationGain(identity: FaceTuning.animeIdentity), 1)
        // Frames of future audio: the lead rounded to frames, plus one.
        XCTAssertEqual(FaceTuning.instantLookahead(lead: 83), 3)
        XCTAssertEqual(FaceTuning.instantLookahead(lead: 46), 2)
        XCTAssertEqual(FaceTuning.instantLookahead(lead: 0), 1)
        // (2 x lookahead + 1) x 20 - lead + drawing (30) + spare (20) + the GPU renderer's extra (20).
        XCTAssertEqual(FaceTuning.instantVoiceDelay(lookahead: 3, lead: 83), 127)
        XCTAssertEqual(FaceTuning.instantVoiceDelay(lookahead: 2, lead: 46), 124)
    }

    func testTheLunaLipPictureIsKeyedByHerPackIdentity() {
        XCTAssertEqual(LipPicture.face(identity: FaceTuning.lunaIdentity), .luna)
        XCTAssertNil(LipPicture.face(identity: FaceTuning.animeIdentity), "the anime's own paste matte already keeps the host's detail")
    }

    func testTheCDNLunaWindowWalksWithoutAHeadPath() {
        let window = AvatarPack.CalmHostWindow(first: 1, count: 9, framesPerHost: 3, wideLast: 34)
        XCTAssertTrue(window.fits(hostCount: 35), "the trimmed pack: calm 1-9, speech out to 34")
        XCTAssertFalse(window.fits(hostCount: 34))
        XCTAssertFalse(window.hasPath, "the speech walk (HostWalker) drives it, not HostPath")
    }

    func testAnimeHeadPathParsesAndFitsItsPack() throws {
        let window = try XCTUnwrap(AvatarPack.CalmHostWindow(json: Data(Self.animeWindow.utf8)))
        XCTAssertTrue(window.hasPath)
        XCTAssertTrue(window.fits(hostCount: 76))
        XCTAssertFalse(window.fits(hostCount: 75))
        XCTAssertTrue(window.isClosedLips(45), "silence shows the host's own closed lips")
        XCTAssertNil(window.wideLast)
    }

    func testManifestTuningFieldsDecodeAndValidate() throws {
        let manifest = try decode(Self.manifestJSON(extra: #""calmWindow": "calm-window.json", "lipLeadMilliseconds": 46, "articulationGain": 1.1,"#))
        XCTAssertEqual(manifest.calmWindow, "calm-window.json")
        XCTAssertEqual(manifest.lipLeadMilliseconds, 46)
        XCTAssertEqual(manifest.articulationGain, 1.1)
        XCTAssertNoThrow(try manifest.validate())

        let plain = try decode(Self.manifestJSON(extra: ""))
        XCTAssertNil(plain.calmWindow); XCTAssertNil(plain.lipLeadMilliseconds); XCTAssertNil(plain.articulationGain)
        XCTAssertNoThrow(try plain.validate())

        XCTAssertThrowsError(try decode(Self.manifestJSON(extra: #""calmWindow": "missing.json","#)).validate())
        XCTAssertThrowsError(try decode(Self.manifestJSON(extra: #""calmWindow": "../calm-window.json","#)).validate())
        XCTAssertThrowsError(try decode(Self.manifestJSON(extra: #""lipLeadMilliseconds": 900,"#)).validate())
        XCTAssertThrowsError(try decode(Self.manifestJSON(extra: #""articulationGain": 3,"#)).validate())
        XCTAssertThrowsError(try decode(Self.manifestJSON(extra: #""calmWindow": "calm-window.json","#, engine: "anime")).validate())
    }

    private func decode(_ json: String) throws -> CharacterManifest {
        try JSONDecoder().decode(CharacterManifest.self, from: Data(json.utf8))
    }

    private static func manifestJSON(extra: String, engine: String = "realistic") -> String {
        let digest = String(repeating: "a", count: 64)
        func file(_ path: String, tier: Int) -> String {
            #"{"path": "\#(path)", "size": 1, "sha256": "\#(digest)", "tier": \#(tier), "chunks": [{"sha256": "\#(digest)", "size": 1}]}"#
        }
        return """
        {"schema": 1, "character": "luna-anime-v2", "version": "2026.09.25.1", "engine": "\(engine)", "displayName": "Luna",
         "width": 1080, "height": 1920, "poster": "poster.jpg", "idle": {"frames": ["idle/idle-00.jpg"], "fps": 8.333},
         \(extra) "minSDK": "0.1.0",
         "files": [\(file("poster.jpg", tier: 0)), \(file("idle/idle-00.jpg", tier: 1)), \(file("calm-window.json", tier: 2))]}
        """
    }

    /// The anime character's head path (one closed-lip lane, 0-75, walked forward and back, the host's own blink at 30-34).
    static let animeWindow = """
    {"first": 45, "count": 1, "framesPerHost": 3, "twins": [[35, 54]], "blinkHosts": [], "closedEyes": [30, 34],
     "lanes": [[0, 75]], "closedLipLanes": [[0, 75]], "itinerary": [[75, 74]], "stays": [60, 90, 75],
     "speechLanes": [[0, 75]], "speechItinerary": [[75, 74]], "speechStays": [60, 90, 75],
     "entries": {}, "exits": {}, "pathStart": 45, "pathStartRising": true}
    """
}

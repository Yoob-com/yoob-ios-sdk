import Foundation

extension AvatarPack.CalmHostWindow {
    /// A window from JSON: a DEBUG test face's `calm-window.json` (`TestFace`) or `AvatarModelProbe --calm-window`. The
    /// fields are the initializer's, ranges as [low, high], crossings as [from, to], `entries` and `exits` keyed by host
    /// (as strings); a field left out takes the initializer's default. Nil when any field is malformed.
    public init?(json data: Data) {
        struct Fields: Decodable {
            let first: Int, count: Int, framesPerHost: Int
            let twins: [[Int]]?, blinkHosts: [[Int]]?, closedEyes: [Int]?
            let lanes: [[Int]]?, closedLipLanes: [[Int]]?, itinerary: [[Int]]?, stays: [Int]?, openLipStays: [Int]?
            let speechLanes: [[Int]]?, speechItinerary: [[Int]]?, speechStays: [Int]?
            let entries: [String: Int]?, exits: [String: Int]?, pathStart: Int?, pathStartRising: Bool?
        }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: data) else { return nil }
        func ranges(_ values: [[Int]]?) -> [ClosedRange<Int>]? {
            guard let values else { return [] }
            guard values.allSatisfy({ $0.count == 2 && $0[0] <= $0[1] }) else { return nil }
            return values.map { $0[0]...$0[1] }
        }
        func crossings(_ values: [[Int]]?) -> [HostPath.Crossing]? {
            guard let values else { return [] }
            guard values.allSatisfy({ $0.count == 2 }) else { return nil }
            return values.map { HostPath.Crossing($0[0], $0[1]) }
        }
        func hosts(_ values: [String: Int]?) -> [Int: Int]? {
            var result: [Int: Int] = [:]
            for (key, value) in values ?? [:] { guard let host = Int(key) else { return nil }; result[host] = value }
            return result
        }
        guard let twins = ranges(fields.twins), let blinkHosts = ranges(fields.blinkHosts), let lanes = ranges(fields.lanes),
              let speechLanes = ranges(fields.speechLanes), let itinerary = crossings(fields.itinerary),
              let speechItinerary = crossings(fields.speechItinerary), let entries = hosts(fields.entries), let exits = hosts(fields.exits),
              fields.closedEyes.map({ $0.count == 2 && $0[0] <= $0[1] }) ?? true else { return nil }
        self.init(first: fields.first, count: fields.count, framesPerHost: fields.framesPerHost, twins: twins, blinkHosts: blinkHosts,
                  closedEyes: fields.closedEyes.map { $0[0]...$0[1] }, lanes: lanes,
                  closedLipLanes: fields.closedLipLanes.flatMap { ranges($0) }, itinerary: itinerary, stays: fields.stays ?? [],
                  openLipStays: fields.openLipStays, speechLanes: speechLanes, speechItinerary: speechItinerary,
                  speechStays: fields.speechStays ?? [], entries: entries, exits: exits, pathStart: fields.pathStart,
                  pathStartRising: fields.pathStartRising ?? true)
    }
}

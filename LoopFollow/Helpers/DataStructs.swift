// LoopFollow
// DataStructs.swift

import Foundation

class DataStructs {
    // Pie Chart Data
    struct pieData: Codable {
        var name: String
        var value: Double
    }

    // NS Basal Profile  Struct
    struct basalProfileSegment: Codable {
        var basalRate: Double
        var startDate: TimeInterval
        var endDate: TimeInterval
    }

    // NS Timestamp Only Data  Struct
    struct timestampOnlyStruct: Codable {
        var date: TimeInterval
        var sgv: Int
    }

    // NS Note Data  Struct
    struct noteStruct: Codable {
        var date: TimeInterval
        var sgv: Int
        var note: String
        /// The uploader that wrote the note, from Nightscout's `app` field.
        /// Rescue carbs are notes and so are Trio's pump-suspend records, so
        /// this is what tells them apart -- the text is not a safe test.
        var app: String?
    }

    // NS Battery Data  Struct
    struct batteryStruct: Codable {
        var batteryLevel: Double
        var timestamp: Date
    }

    // NS Override Data  Struct
    struct overrideStruct: Codable {
        var insulNeedsScaleFactor: Double
        var date: TimeInterval
        var endDate: TimeInterval
        var duration: Double
        var correctionRange: [Int]
        var enteredBy: String
        var reason: String
        var sgv: Float
    }

    struct tempTargetStruct: Codable {
        var date: TimeInterval
        var endDate: TimeInterval
        var duration: Double
        var correctionRange: [Int]
        var enteredBy: String
        var reason: String
    }
}

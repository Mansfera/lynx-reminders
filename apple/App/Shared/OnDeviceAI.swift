import Foundation
import LynxCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Quick add read by Apple Intelligence's on-device model (SPEC §7a): free, private, no key. iOS/macOS 26 on
/// devices with Apple Intelligence turned on; everything else reports why it can't.
enum OnDeviceAI {
    enum Status: Equatable {
        case available
        /// Older iOS/macOS, or a device without Apple Intelligence.
        case unsupported
        case turnedOff
        case downloading
        case unavailable

        /// Worth showing in Settings: usable now, or soon without the user doing anything.
        var shown: Bool { self == .available || self == .downloading }

        var label: String {
            switch self {
            case .available: "Ready"
            case .unsupported: "Not on this device"
            case .turnedOff: "Turn on Apple Intelligence in Settings"
            case .downloading: "Model still downloading"
            case .unavailable: "Not available right now"
            }
        }
    }

    static let name = "Apple Intelligence"

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unsupported
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .downloading
            case .unavailable: return .unavailable
            }
        }
        #endif
        return .unsupported
    }

    static func read(_ text: String, lists: [LynxList], now: Date, timeZone: TimeZone = .current) async throws -> QuickAddResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: QuickAddAI.systemPrompt)
            let reply = try await session.respond(
                to: QuickAddAI.userMessage(text, lists: lists, now: now, timeZone: timeZone),
                generating: OnDeviceFields.self,
                options: GenerationOptions(sampling: .greedy))
            return QuickAddAI.result(from: reply.content.fields, original: text, lists: lists, now: now, timeZone: timeZone)
        }
        #endif
        throw ClaudeError.http(0, "\(name) isn't available on this device.")
    }
}

#if canImport(FoundationModels)
/// The reminder fields for guided generation: the on-device model can only answer in this shape.
@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct OnDeviceRepeat {
    @Guide(description: "Repeat unit", .anyOf(["minute", "hour", "day", "week", "month", "year"]))
    var unit: String
    @Guide(description: "Number of units between repeats", .range(1...1000))
    var interval: Int
    @Guide(description: "ISO weekdays (1 Monday … 7 Sunday) for weekly repeats on given days, otherwise empty")
    var weekdays: [Int]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct OnDeviceFields {
    @Guide(description: "The thing to do, short, without date, time, repeat, priority or list words")
    var title: String
    @Guide(description: "Extra detail that doesn't fit the title, usually null")
    var notes: String?
    @Guide(description: "YYYY-MM-DD, or null when no day is mentioned or implied")
    var date: String?
    @Guide(description: "HH:MM in 24-hour time, or null for all day")
    var time: String?
    @Guide(description: "The repeat, or null when the line asks for none")
    var repetition: OnDeviceRepeat?
    @Guide(description: "0 none, 1 low, 2 medium, 3 high", .range(0...3))
    var priority: Int
    @Guide(description: "Exact name of one of the user's lists, or null")
    var list: String?

    var fields: QuickAddAI.Fields {
        QuickAddAI.Fields(title: title, notes: notes, date: date, time: time,
                          repeat: repetition.map { .init(unit: $0.unit, interval: $0.interval, weekdays: $0.weekdays) },
                          priority: priority, list: list)
    }
}
#endif

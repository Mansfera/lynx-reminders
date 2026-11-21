// Prints the window number of the named app's largest on-screen window (for screencapture -l).
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Lynx Reminders"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
let sized = mine.map { w -> (Int, Double) in
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (w[kCGWindowNumber as String] as? Int ?? 0, (b["Width"] ?? 0) * (b["Height"] ?? 0))
}
if let best = sized.max(by: { $0.1 < $1.1 }) { print(best.0) }

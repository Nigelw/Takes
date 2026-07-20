// Prints the frontmost normal window of an app as: <id>\t<x>\t<y>\t<w>\t<h>
// Usage: swift window-info.swift "Takes"
// The release skill uses the window id for `screencapture -l<id>`. Uses owner
// name only, so no Screen Recording permission is needed to look up the id
// (capturing content still is).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: swift window-info.swift <AppName>\n".data(using: .utf8)!); exit(2)
}
let app = CommandLine.arguments[1]
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list {
    guard (w[kCGWindowLayer as String] as? Int) == 0,
          (w[kCGWindowOwnerName as String] as? String) == app,
          let num = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    print("\(num)\t\(Int(b["X"]!))\t\(Int(b["Y"]!))\t\(Int(b["Width"]!))\t\(Int(b["Height"]!))")
    exit(0)   // frontmost match only
}
FileHandle.standardError.write("no on-screen window for \(app)\n".data(using: .utf8)!); exit(1)

// post_pointer.swift -- a mouse drag posted to one process, as a mouse would send it (`tools/masks_check.sh`):
//
//   post_pointer <pid> <x1> <y1> <x2> <y2> <window width> <window height>
//
// The points are in the app's own window coordinates (UIKit's, top left, as `--masks-check` prints them with the
// window's size); the app's largest on-screen window (CGWindowList, by its process id) gives where that window is on
// the screen and its scale (Catalyst draws a window of UIKit points smaller on the Mac). Then: the pointer moved to the
// first point, the button down, twenty drags to the second, the button up -- each through `CGEvent.postToPid`, so
// nothing reaches another app. Prints the screen points it used.
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count == 8, let pid = pid_t(a[1]), let x1 = Double(a[2]), let y1 = Double(a[3]), let x2 = Double(a[4]), let y2 = Double(a[5]),
      let ww = Double(a[6]), let wh = Double(a[7]) else { print("usage: post_pointer <pid> x1 y1 x2 y2 w h"); exit(2) }
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let (best, number) = mine.compactMap({ w -> (CGRect, Int)? in
        guard let b = w[kCGWindowBounds as String] as? [String: Double], let n = w[kCGWindowNumber as String] as? Int else { return nil }
        return (CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0), n)
    }).max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height }) else { print("no window of \(pid) on screen"); exit(1) }
let sx = best.width / ww, sy = best.height / wh
func screen(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: best.minX + x * sx, y: best.minY + y * sy) }
let p1 = screen(x1, y1), p2 = screen(x2, y2)
print(String(format: "window %.0f,%.0f %.0fx%.0f, scale %.3f x %.3f: %.1f,%.1f -> %.1f,%.1f", best.minX, best.minY, best.width, best.height, sx, sy, p1.x, p1.y, p2.x, p2.y))
let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    // The window under the pointer, as the window server would have said: an event posted to a process is not hit-tested.
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.postToPid(pid)
}
post(.mouseMoved, p1); usleep(150_000)
post(.leftMouseDown, p1); usleep(80_000)
for i in 1...20 {
    let t = Double(i) / 20
    post(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t))
    usleep(16_000)
}
post(.leftMouseUp, p2)
print("posted a drag to \(pid)")

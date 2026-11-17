// Geometry.swift — pure window-layout math.
//
// All rects use Accessibility coordinates: origin at the top-left of the
// primary display, y increasing downward. `screens` are each display's
// *visible* frame (excluding the menu bar and Dock).

import CoreGraphics

enum WindowAction: String, CaseIterable {
    case left, right, up, down
    case upLeft, upRight, downLeft, downRight
    case center, left40, right60, maximize
    case nextScreen, screenEast, screenWest
}

enum Geometry {
    /// Where the window should go, or nil if the action can't apply
    /// (e.g., there's no display to the east).
    static func target(for action: WindowAction, window w: CGRect, screens: [CGRect]) -> CGRect? {
        guard let current = screenIndex(for: w, screens: screens) else { return nil }
        let s = screens[current]

        switch action {
        case .left:      return rect(s, 0, 0, 0.5, 1)
        case .right:     return rect(s, 0.5, 0, 0.5, 1)
        case .up:        return rect(s, 0, 0, 1, 0.5)
        case .down:      return rect(s, 0, 0.5, 1, 0.5)
        case .upLeft:    return rect(s, 0, 0, 0.5, 0.5)
        case .upRight:   return rect(s, 0.5, 0, 0.5, 0.5)
        case .downLeft:  return rect(s, 0, 0.5, 0.5, 0.5)
        case .downRight: return rect(s, 0.5, 0.5, 0.5, 0.5)
        case .center:    return rect(s, 0.2, 0, 0.6, 1)
        case .left40:    return rect(s, 0, 0, 0.4, 1)
        case .right60:   return rect(s, 0.4, 0, 0.6, 1)
        case .maximize:  return rect(s, 0, 0, 1, 1)
        case .nextScreen:
            guard screens.count > 1 else { return nil }
            return move(w, from: s, to: screens[(current + 1) % screens.count])
        case .screenEast, .screenWest:
            let east = action == .screenEast
            let candidates = screens.indices.filter {
                $0 != current && (east ? screens[$0].midX > s.midX : screens[$0].midX < s.midX)
            }
            guard let best = candidates.min(by: { distance(screens[$0], s) < distance(screens[$1], s) })
            else { return nil }
            return move(w, from: s, to: screens[best])
        }
    }

    /// The display the window overlaps most; falls back to the nearest one.
    static func screenIndex(for w: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { s -> CGFloat in
            let r = s.intersection(w)
            return r.isNull ? 0 : r.width * r.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        return screens.indices.min(by: { distance(screens[$0], w) < distance(screens[$1], w) })
    }

    /// A fraction of a screen, rounded to whole points.
    private static func rect(_ s: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let minX = (s.minX + s.width * x).rounded(), minY = (s.minY + s.height * y).rounded()
        let maxX = (s.minX + s.width * (x + w)).rounded(), maxY = (s.minY + s.height * (y + h)).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Keep the window's position and size proportional when changing displays.
    private static func move(_ w: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let fx = (w.minX - a.minX) / a.width, fy = (w.minY - a.minY) / a.height
        let fw = min(w.width / a.width, 1), fh = min(w.height / a.height, 1)
        let x = min(max(fx, 0), 1 - fw), y = min(max(fy, 0), 1 - fh)
        return rect(b, x, y, fw, fh)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}

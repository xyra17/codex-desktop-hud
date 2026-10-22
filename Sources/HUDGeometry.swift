import Foundation
import CoreGraphics

// Coordinates stored relative to the host, so moving/resizing the host keeps the HUD inside it.
enum HUDGeometry {
    static func frame(host: CGRect, width: CGFloat, height: CGFloat,
                      position: CGPoint?) -> CGRect {
        let inset: CGFloat = 8
        let w = min(width, max(1, host.width - inset * 2))
        let h = min(height, max(1, host.height - inset * 2))
        let travelX = max(0, host.width - inset * 2 - w)
        let travelY = max(0, host.height - inset * 2 - h)
        let pos = position ?? CGPoint(x: 1, y: host.width < 1050 ? min(1, 48 / max(1, travelY)) : 0)
        return CGRect(x: host.minX + inset + min(1, max(0, pos.x)) * travelX,
                      y: host.maxY - inset - h - min(1, max(0, pos.y)) * travelY,
                      width: w, height: h)
    }

    static func position(origin: CGPoint, host: CGRect, size: CGSize) -> CGPoint {
        let dx = host.width - 16 - size.width
        let x = dx > 0 ? (origin.x - host.minX - 8) / dx : 0
        let dy = host.height - 16 - size.height
        let y = dy > 0 ? (host.maxY - 8 - size.height - origin.y) / dy : 0
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

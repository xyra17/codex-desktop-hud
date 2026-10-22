import Foundation
import CoreGraphics

@main struct GeometryTests {
    static func main() {
        for host in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                     CGRect(x: -1800, y: -500, width: 800, height: 600),
                     CGRect(x: 200, y: 300, width: 430, height: 270)] {
            for width: CGFloat in [410, 760] {
                for origin in [CGPoint(x: -99999, y: -99999), CGPoint(x: 99999, y: 99999)] {
                    let initial = HUDGeometry.frame(host: host, width: width, height: 96, position: nil)
                    let pos = HUDGeometry.position(origin: origin, host: host, size: initial.size)
                    let clamped = HUDGeometry.frame(host: host, width: width, height: 96, position: pos)
                    precondition(host.contains(clamped), "Drag must remain inside host")
                    let roundTrip = HUDGeometry.position(origin: clamped.origin, host: host, size: clamped.size)
                    precondition(abs(roundTrip.x - pos.x) < 0.001 && abs(roundTrip.y - pos.y) < 0.001)
                }
            }
            let defaultFrame = HUDGeometry.frame(host: host, width: 350, height: 96, position: nil)
            precondition(host.contains(defaultFrame))
            let resized = HUDGeometry.frame(host: host, width: 760, height: 96, position: CGPoint(x: 1, y: 1))
            precondition(host.contains(resized))
        }
        print("Geometry: drag clamps, resize, compact/expanded and negative screen coordinates passed")
    }
}

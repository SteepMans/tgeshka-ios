import Foundation
import UIKit

// TGeshka: the badge next to the names of other TGeshka users, the app icon in small:
// a lavender circle with the white paper plane.

private var tgeshkaBadgeImages: [CGFloat: UIImage] = [:]
private let tgeshkaBadgeLock = NSLock()

public let tgeshkaBadgeColor = UIColor(red: 0x83 / 255.0, green: 0x66 / 255.0, blue: 0xcc / 255.0, alpha: 1.0)

/// The badge image of the given side (points), cached per size.
public func tgeshkaBadgeImage(size: CGFloat) -> UIImage? {
    tgeshkaBadgeLock.lock()
    if let image = tgeshkaBadgeImages[size] {
        tgeshkaBadgeLock.unlock()
        return image
    }
    tgeshkaBadgeLock.unlock()
    let image = generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        let scale = size.width / 24.0
        context.setFillColor(tgeshkaBadgeColor.cgColor)
        context.fillEllipse(in: CGRect(origin: CGPoint(), size: size))

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            return CGPoint(x: x * scale, y: y * scale)
        }
        let plane: [CGPoint] = [point(4.86, 11.85), point(19.14, 6.05), point(16.46, 18.55), point(12.45, 15.87), point(10.21, 18.10), point(9.99, 14.31)]
        context.setFillColor(UIColor.white.cgColor)
        context.beginPath()
        context.addLines(between: plane)
        context.closePath()
        context.fillPath()

        let fold: [CGPoint] = [point(9.99, 14.31), point(17.58, 7.84), point(12.45, 15.87), point(10.21, 18.10)]
        context.setFillColor(UIColor(red: 0xe6 / 255.0, green: 0xdf / 255.0, blue: 1.0, alpha: 1.0).cgColor)
        context.beginPath()
        context.addLines(between: fold)
        context.closePath()
        context.fillPath()
    })
    if let image = image {
        tgeshkaBadgeLock.lock()
        tgeshkaBadgeImages[size] = image
        tgeshkaBadgeLock.unlock()
    }
    return image
}

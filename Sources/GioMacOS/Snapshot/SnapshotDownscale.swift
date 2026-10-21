import CoreGraphics

/// PF-AS: `image` scaled down to at most `pixelsPerPoint` of a window whose
/// frame is `pointSize`, keeping the image's aspect (one `CGContext` draw,
/// medium interpolation). An image already at or below that density is
/// returned as is, never scaled up or copied. Nil only when no bitmap context
/// can be made. Pure CPU work: call it off the main thread and off the session
/// queue.
public func snapshotDownscaled(_ image: CGImage, pointSize: CGSize, pixelsPerPoint: CGFloat) -> CGImage? {
    let sourceWidth = CGFloat(image.width)
    let sourceHeight = CGFloat(image.height)
    let factor = min(
        1, pointSize.width * pixelsPerPoint / sourceWidth, pointSize.height * pixelsPerPoint / sourceHeight
    )
    guard factor < 1 else {
        return image
    }
    let width = max(1, Int((sourceWidth * factor).rounded()))
    let height = max(1, Int((sourceHeight * factor).rounded()))
    // The capture's own RGB space (no conversion); any other model falls back to sRGB.
    let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return nil
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

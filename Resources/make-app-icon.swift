// Builds Resources/Assets.xcassets/AppIcon.appiconset from the artwork in
// Resources/AppIcon-source.jpeg.
//   swift "Resources/make-app-icon.swift" [source] [output-folder]
// The artwork comes on a white square with a light rim around its rounded
// body. The body is found (the white connected to the corners is the
// surround), trimmed by `rimInset` and re-masked with a clean macOS
// corner, fitted to the icon grid (824 pt inside 1024) with the standard
// soft shadow, and every size of the set is written.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
let source = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Resources/AppIcon-source.jpeg")
let folder = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/Assets.xcassets/AppIcon.appiconset",
                 isDirectory: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// Fraction of the body trimmed on every side to drop the artwork's light rim.
let rimInset: CGFloat = 0.03

/// The bounds of the artwork's body in the bitmap's top-down rows: every
/// pixel that is not near-white surround reachable from the corners (white
/// inside the artwork, clouds and panels, is not reachable and counts).
func bodyBounds(_ image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    let context = bitmap(width, height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    func isSurround(_ index: Int) -> Bool {
        min(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2]) >= 236
    }
    var reached = [Bool](repeating: false, count: width * height)
    var stack = [0, width - 1, (height - 1) * width, height * width - 1].filter(isSurround)
    for index in stack {
        reached[index] = true
    }
    while let index = stack.popLast() {
        let x = index % width, y = index / width
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < width, ny < height else {
                continue
            }
            let next = ny * width + nx
            if !reached[next], isSurround(next) {
                reached[next] = true
                stack.append(next)
            }
        }
    }
    var minX = width, minY = height, maxX = 0, maxY = 0
    for index in 0..<(width * height) where !reached[index] {
        let x = index % width, y = index / width
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// The 1024 master: the body (minus its rim) as a square filling the 824 pt
/// grid, clipped to the macOS corner radius, over a soft shadow.
func master(from artwork: CGImage) -> CGImage {
    let bounds = bodyBounds(artwork)
    let side = min(bounds.width, bounds.height)
    let trim = side * rimInset
    // Top-down crop rectangle, square and centred on the body.
    let crop = CGRect(
        x: bounds.midX - side / 2 + trim, y: bounds.midY - side / 2 + trim,
        width: side - trim * 2, height: side - trim * 2
    ).integral
    let body = artwork.cropping(to: crop)!
    let context = bitmap(1024, 1024)
    context.interpolationQuality = .high
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10), blur: 24,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3)
    )
    context.addPath(shape)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.addPath(shape)
    context.clip()
    context.draw(body, in: rect)
    return context.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) {
    let context = bitmap(size, size)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

guard let artwork = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(source.path)")
}
let icon = master(from: artwork)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(icon, size: points * scale, to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: folder.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(folder.path)")

import AppKit
import SwiftUI

/// The chameleon holding its windows: Gio's mascot, shared with the landing
/// page (`gio-landing/src/assets/gio-mascot.png`, downscaled).
@MainActor
private let mascotImage: NSImage? = Bundle.module.image(forResource: "gio-mascot")

/// The mascot at `size` points tall (its art is a little taller than wide).
/// A mint tile with the strip glyph stands in if the resource is missing.
public struct GioMascot: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Group {
            if let mascotImage {
                Image(nsImage: mascotImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(GioColor.tintFill(.green))
                    .overlay(
                        Image(systemName: "rectangle.split.3x1.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(GioBrand.onSpot)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The landing page's hand-drawn emphasis: a wavy line under a word.
struct Squiggle: Shape {
    var wavelength: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let amplitude = rect.height / 2
        path.move(to: CGPoint(x: rect.minX, y: mid))
        var x = rect.minX
        var up = true
        while x < rect.maxX {
            let next = min(x + wavelength / 2, rect.maxX)
            path.addQuadCurve(
                to: CGPoint(x: next, y: mid),
                control: CGPoint(x: (x + next) / 2, y: up ? mid - amplitude * 2 : mid + amplitude * 2)
            )
            up.toggle()
            x = next
        }
        return path
    }
}

extension View {
    /// Underline with Gio's squiggle in `color`.
    func squiggleUnderline(_ color: Color) -> some View {
        overlay(alignment: .bottom) {
            Squiggle()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(height: 5)
                .offset(y: 6)
        }
    }
}
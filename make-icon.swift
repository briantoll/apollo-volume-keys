#!/usr/bin/env swift
// Draws the app icon (an Apollo Twin style level ring around the monitor knob)
// and writes AppIcon.icns next to this script. AppIcon.icns is checked in, so
// this only needs re-running when the design changes:
//
//   swift make-icon.swift [iconset-dir]
//
// With an argument the intermediate .iconset is kept there for inspection, and
// a preview of the light variant is written beside it as AppIcon-light.png.
//
// The .icns holds one appearance, the dark plate, used in every system icon
// style. System-switched light and tinted variants would need an Icon Composer
// icon compiled into Assets.car by Xcode's actool; the light render is a
// design preview for that, not its layers.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}
func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { rgb(w, w, w, a) }

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

/// Everything is drawn in a 1024-unit space (origin bottom-left) and scaled,
/// so each size is rendered natively rather than downsampled.
func render(pixels: Int, dark: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high

    let center = CGPoint(x: 512, y: 512)
    let unit = CGFloat(pixels) / 1024   // shadows are specified in pixels

    // --- Plate: the macOS icon shape, measured from stock system icons ----
    // 824pt square on the 1024 grid whose corners are superellipse arcs
    // (250pt corner box, exponent 2.39) rather than circular arcs.
    let plate = CGMutablePath()
    let lo: CGFloat = 100, hi: CGFloat = 924, box: CGFloat = 250, expo: CGFloat = 2 / 2.39
    let corners: [(CGFloat, CGFloat, CGFloat)] = [   // corner-box centre, start angle
        (hi - box, hi - box, 0), (lo + box, hi - box, .pi / 2),
        (lo + box, lo + box, .pi), (hi - box, lo + box, 3 * .pi / 2),
    ]
    for (cx, cy, start) in corners {
        for i in 0...48 {
            let t = start + CGFloat(i) / 48 * .pi / 2
            let c = cos(t), s = sin(t)
            let p = CGPoint(x: cx + box * (c < 0 ? -1 : 1) * pow(abs(c), expo),
                            y: cy + box * (s < 0 ? -1 : 1) * pow(abs(s), expo))
            if plate.isEmpty { plate.move(to: p) } else { plate.addLine(to: p) }
        }
    }
    plate.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 18 * unit,
                  color: gray(0, 0.3))
    ctx.addPath(plate)
    ctx.setFillColor(gray(dark ? 0.1 : 0.8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    linearGradient(ctx, dark ? [gray(0.17), gray(0.07)] : [gray(0.90), gray(0.75)],
                   from: CGPoint(x: 512, y: hi), to: CGPoint(x: 512, y: lo))
    // Glass rim: a thin specular edge, brightest top-left and bottom-right.
    // Kept faint because macOS 26+ re-masks a legacy .icns to its own icon
    // shape and adds its own rim and shadow on top.
    ctx.addPath(plate)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim: [CGFloat] = dark ? [0.3, 0.04, 0.04, 0.18] : [0.6, 0.1, 0.1, 0.4]
    linearGradient(ctx, rim.map { gray(1, $0) },
                   from: CGPoint(x: lo + 60, y: hi - 60), to: CGPoint(x: hi - 60, y: lo + 60))
    ctx.restoreGState()

    // --- Black glass display behind the ring -------------------------------
    let glassR: CGFloat = 352
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, glassR + 8))
    ctx.clip()
    linearGradient(ctx, dark ? [gray(0.03), gray(0.34)] : [gray(0.55), gray(1.0)],
                   from: CGPoint(x: 512, y: 512 + glassR), to: CGPoint(x: 512, y: 512 - glassR))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: circle(center, glassR))
    ctx.clip()
    linearGradient(ctx, dark ? [gray(0.06), gray(0.0)] : [gray(0.13), gray(0.03)],
                   from: CGPoint(x: 512, y: 512 + glassR), to: CGPoint(x: 512, y: 512 - glassR))
    ctx.restoreGState()

    // --- LED level ring: 270° sweep, gap at the bottom ---------------------
    let ringInner: CGFloat = 252
    let ringOuter: CGFloat = 318
    let startDeg: CGFloat = 225, sweepDeg: CGFloat = 270
    let litFraction: CGFloat = 0.7
    let green = rgb(0.25, 0.96, 0.36)
    let unlit = gray(0.2)

    do {
        let coarse = pixels <= 64   // fine segments smear together; simplify
        let count = coarse ? 17 : 25
        let segWidth: CGFloat = coarse ? 32 : 22
        let litCount = Int((CGFloat(count) * litFraction).rounded())
        for i in 0..<count {
            let deg = startDeg - sweepDeg * CGFloat(i) / CGFloat(count - 1)
            let lit = i < litCount
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: deg * .pi / 180)
            let seg = CGRect(x: ringInner, y: -segWidth / 2,
                             width: ringOuter - ringInner, height: segWidth)
            let path = CGPath(roundedRect: seg, cornerWidth: 5, cornerHeight: 5, transform: nil)
            if lit && !coarse {
                ctx.setShadow(offset: .zero, blur: 26 * unit,
                              color: rgb(0.2, 1.0, 0.35, 0.9))
            }
            ctx.addPath(path)
            ctx.setFillColor(lit ? green : unlit)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // --- Knob ---------------------------------------------------------------
    let knobR: CGFloat = 208

    // Drop shadow onto the glass.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * unit),
                  blur: 28 * unit, color: gray(0, 0.9))
    ctx.addEllipse(in: circle(center, knobR))
    ctx.setFillColor(gray(0.5))
    ctx.fillPath()
    ctx.restoreGState()

    // Chrome bevel.
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, knobR))
    ctx.clip()
    linearGradient(ctx, [gray(1.0), gray(0.62), gray(0.38), gray(0.9)],
                   from: CGPoint(x: 512, y: 512 + knobR), to: CGPoint(x: 512, y: 512 - knobR))
    ctx.restoreGState()

    // Spun-aluminium face: brightness varies with angle, drawn as thin wedges.
    let faceR = knobR - 16
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, faceR))
    ctx.clip()
    let wedges = 720
    let step = 2 * CGFloat.pi / CGFloat(wedges)
    for i in 0..<wedges {
        let a = CGFloat(i) * step
        // Two broad highlights (upper right, lower left) plus fine streaks.
        var w = 0.76 + 0.17 * cos(2 * (a - .pi / 4))
        w += 0.035 * cos(10 * a + 0.6) + 0.02 * cos(26 * a + 1.9)
        ctx.move(to: center)
        ctx.addArc(center: center, radius: faceR + 2, startAngle: a - step * 0.1,
                   endAngle: a + step * 1.1, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(gray(min(max(w, 0), 1)))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Thin dark line separating face from bevel.
    ctx.addEllipse(in: circle(center, faceR))
    ctx.setStrokeColor(gray(0, 0.22))
    ctx.setLineWidth(3)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                               1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let keep = CommandLine.arguments.count > 1
let iconset = keep
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
precondition(iconset.pathExtension == "iconset", "iconset dir must end in .iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// No 16px or 32px images: when an .icns has them, macOS 26+ shrinks the icon
// onto its own light plate at those sizes. Without them it scales down the
// 64px image and leaves the icon alone.
writePNG(render(pixels: 64), to: iconset.appendingPathComponent("icon_32x32@2x.png"))
for points in [128, 256, 512] {
    writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2),
             to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let icns = scriptDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
if keep {
    writePNG(render(pixels: 1024, dark: false),
             to: iconset.deletingLastPathComponent().appendingPathComponent("AppIcon-light.png"))
} else {
    try? fm.removeItem(at: iconset)
}
print("Wrote \(icns.path)")

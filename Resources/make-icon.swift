//
//  make-icon.swift
//  Draws the Audio Cutter app icon from code, at every size macOS asks for.
//
//  WHY GENERATE IT INSTEAD OF SHIPPING A PNG
//  --------------------------------------------------------------------------
//  An icon checked in as a flat image is a dead end: you cannot nudge a colour
//  or a proportion later without opening a paint program and redoing all ten
//  sizes by hand. Drawn from code, the whole icon is one file you can edit, and
//  every size is regenerated in a second. Each size is also drawn fresh rather
//  than scaled down from 1024, which is why the 16pt version stays readable
//  instead of turning to mush.
//
//  THE DESIGN
//  --------------------------------------------------------------------------
//  A dark squircle (Apple's icon shape since Big Sur), a symmetrical waveform
//  across the middle, and one bright vertical cut line. The bars to the right
//  of the line are dimmed: that is the part you are about to throw away. At
//  1024pt you read "waveform being cut". At 16pt, where detail dies, you still
//  read a dark tile with a bright vertical stroke, which is enough to find it
//  in a Dock full of grey tools.
//
//  RUN IT
//      swift Resources/make-icon.swift
//  It writes Resources/AppIcon.icns, which build.sh copies into the bundle.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
// These match Theme.swift so the icon and the app agree with each other.

let backgroundTop = (r: 0.129, g: 0.137, b: 0.153)   // charcoal, lit from above
let backgroundBottom = (r: 0.055, g: 0.059, b: 0.067)
let waveColour = (r: 0.78, g: 0.82, b: 0.87)         // the audio you keep
let accent = (r: 1.00, g: 0.58, b: 0.20)             // the cut

/// Bar heights as a fraction of the half-height available. Hand-tuned rather
/// than random: it reads as speech, with a loud passage before the cut and a
/// quieter tail after it.
let barEnvelope: [CGFloat] = [
    0.22, 0.40, 0.30, 0.62, 0.86, 0.54, 0.96, 0.70,
    0.44, 0.78, 0.34, 0.52, 0.26, 0.38, 0.20
]

/// Which bar the cut line falls after. Everything past it is dimmed.
let cutAfterBar = 8

// MARK: - Drawing

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024                     // all geometry is authored at 1024
    let width = Int(size)
    let height = Int(size)

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    // macOS icons do not fill their canvas. The artwork sits in the middle
    // 824 of 1024 points, leaving transparent margin for the system's own
    // shadow and hover effects.
    let inset: CGFloat = 100 * scale
    let plate = CGRect(
        x: inset,
        y: inset,
        width: size - inset * 2,
        height: size - inset * 2
    )
    // Corner radius as a proportion of the plate, matching the system shape.
    let radius = plate.width * 0.2255

    let plateShape = CGPath(
        roundedRect: plate,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    // Background: a soft top-to-bottom gradient so the tile does not look
    // like a flat rectangle of paint.
    context.saveGState()
    context.addPath(plateShape)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: backgroundTop.r, green: backgroundTop.g,
                    blue: backgroundTop.b, alpha: 1),
            CGColor(red: backgroundBottom.r, green: backgroundBottom.g,
                    blue: backgroundBottom.b, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }

    // MARK: Waveform

    let count = barEnvelope.count
    // Bars live inside a generous margin so nothing crowds the rounded corners.
    let field = plate.insetBy(dx: plate.width * 0.135, dy: plate.height * 0.20)
    let slot = field.width / CGFloat(count)
    let barWidth = slot * 0.44                 // the rest is the gap
    let capRadius = barWidth / 2
    let centreY = field.midY
    let maxHalf = field.height / 2

    for (index, envelope) in barEnvelope.enumerated() {
        let isDiscarded = index >= cutAfterBar
        let alpha: CGFloat = isDiscarded ? 0.26 : 1.0

        // Never let a bar collapse to nothing at 16pt: keep a visible minimum.
        let half = max(envelope * maxHalf, capRadius * 1.1)
        let x = field.minX + slot * CGFloat(index) + (slot - barWidth) / 2
        let bar = CGRect(x: x, y: centreY - half, width: barWidth, height: half * 2)

        context.setFillColor(
            CGColor(red: waveColour.r, green: waveColour.g,
                    blue: waveColour.b, alpha: alpha)
        )
        context.addPath(
            CGPath(roundedRect: bar, cornerWidth: capRadius,
                   cornerHeight: capRadius, transform: nil)
        )
        context.fillPath()
    }

    // MARK: The cut

    let cutX = field.minX + slot * CGFloat(cutAfterBar) - slot * 0.06
    let cutWidth = max(size * 0.028, 1.5)
    let cutRect = CGRect(
        x: cutX - cutWidth / 2,
        y: plate.minY + plate.height * 0.11,
        width: cutWidth,
        height: plate.height * 0.78
    )

    // A faint glow first, so the line feels like it is emitting rather than
    // just sitting there. Skipped at tiny sizes where it would only smear.
    if size >= 64 {
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: size * 0.035,
            color: CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 0.75)
        )
        context.setFillColor(
            CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1)
        )
        context.addPath(
            CGPath(roundedRect: cutRect, cornerWidth: cutWidth / 2,
                   cornerHeight: cutWidth / 2, transform: nil)
        )
        context.fillPath()
        context.restoreGState()
    }

    context.setFillColor(
        CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1)
    )
    context.addPath(
        CGPath(roundedRect: cutRect, cornerWidth: cutWidth / 2,
               cornerHeight: cutWidth / 2, transform: nil)
    )
    context.fillPath()

    context.restoreGState()

    // A hairline highlight along the top edge of the plate. This is the trick
    // that stops a dark icon from looking like a hole in the Dock.
    if size >= 64 {
        context.saveGState()
        context.addPath(plateShape)
        context.clip()
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.09))
        context.setLineWidth(size * 0.006)
        context.addPath(
            CGPath(roundedRect: plate.insetBy(dx: size * 0.003, dy: size * 0.003),
                   cornerWidth: radius, cornerHeight: radius, transform: nil)
        )
        context.strokePath()
        context.restoreGState()
    }

    return context.makeImage()
}

// MARK: - Writing the iconset

/// The exact ten files `iconutil` expects, and the pixel size of each.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    guard let image = drawIcon(size: variant.pixels) else {
        print("could not draw \(variant.name)")
        exit(1)
    }
    let url = iconset.appendingPathComponent(variant.name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        print("could not create \(variant.name)")
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        print("could not write \(variant.name)")
        exit(1)
    }
    print("  \(variant.name)  \(Int(variant.pixels))px")
}

// Hand the folder to Apple's own tool, which packs it into a single .icns.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", here.appendingPathComponent("AppIcon.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("wrote Resources/AppIcon.icns")

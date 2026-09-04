// Slices the 4096² sprite atlas into 36 frames.
// sips is not usable here: its --cropOffset is measured from the image centre,
// which silently produces frames straddling four cells.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: slice <atlas.png> <outDir> [size]\n".utf8))
    exit(1)
}
let atlasURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let target = args.count > 3 ? Int(args[3])! : 256

guard let src = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
      let atlas = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read atlas\n".utf8))
    exit(1)
}

let cols = 6, rows = 6
let w = CGFloat(atlas.width) / CGFloat(cols)
let h = CGFloat(atlas.height) / CGFloat(rows)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for r in 0..<rows {
    for c in 0..<cols {
        let rect = CGRect(x: (CGFloat(c) * w).rounded(),
                          y: (CGFloat(r) * h).rounded(),
                          width: w.rounded(), height: h.rounded())
        guard let cell = atlas.cropping(to: rect) else { continue }

        // Downscale with nearest neighbour so the pixel art stays crisp
        guard let ctx = CGContext(data: nil, width: target, height: target,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { continue }
        ctx.interpolationQuality = .none
        ctx.draw(cell, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let out = ctx.makeImage() else { continue }

        let dst = outDir.appending(path: "f\(r)\(c).png")
        guard let writer = CGImageDestinationCreateWithURL(
            dst as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(writer, out, nil)
        CGImageDestinationFinalize(writer)
    }
}
print("36 frames -> \(outDir.path)")

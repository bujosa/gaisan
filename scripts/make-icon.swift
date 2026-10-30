import AppKit
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard
  let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
  fputs("no context\n", stderr)
  exit(1)
}

let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
context.addPath(rounded(bounds, radius: canvas * 0.2237))
context.clip()

let background = [
  CGColor(srgbRed: 0.16, green: 0.15, blue: 0.13, alpha: 1),
  CGColor(srgbRed: 0.08, green: 0.08, blue: 0.07, alpha: 1),
] as CFArray
let gradient = CGGradient(
  colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: background, locations: [0, 1])!
context.drawLinearGradient(
  gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])

let inset = canvas * 0.18
let gap = canvas * 0.055
let barWidth = (canvas - inset * 2 - gap * 2) / 3
let heights: [CGFloat] = [0.38, 0.62, 0.86]
let colors = [
  CGColor(srgbRed: 0.85, green: 0.45, blue: 0.28, alpha: 1),
  CGColor(srgbRed: 0.22, green: 0.68, blue: 0.48, alpha: 1),
  CGColor(srgbRed: 0.93, green: 0.76, blue: 0.28, alpha: 1),
]
let floor = canvas * 0.18
for (index, height) in heights.enumerated() {
  let barHeight = canvas * height
  let rect = CGRect(
    x: inset + CGFloat(index) * (barWidth + gap),
    y: floor,
    width: barWidth,
    height: barHeight)
  context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
  context.addPath(rounded(CGRect(x: rect.minX, y: floor, width: barWidth, height: canvas * 0.86), radius: barWidth / 2))
  context.fillPath()
  context.setFillColor(colors[index])
  context.addPath(rounded(rect, radius: barWidth / 2))
  context.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = context.makeImage() else {
  fputs("encode failed\n", stderr)
  exit(1)
}
guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
  fputs("destination failed\n", stderr)
  exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
  fputs("write failed\n", stderr)
  exit(1)
}

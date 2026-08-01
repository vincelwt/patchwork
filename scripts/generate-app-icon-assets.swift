#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvasSize = 1024
private let bytesPerPixel = 4
private let bytesPerRow = canvasSize * bytesPerPixel
private let normalizedBubbleSize = 390
private let clusterOrigin = (canvasSize - normalizedBubbleSize * 2) / 2

private enum Bubble: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var filename: String {
        return switch self {
        case .topLeft: "BubbleTopLeft.png"
        case .topRight: "BubbleTopRight.png"
        case .bottomLeft: "BubbleBottomLeft.png"
        case .bottomRight: "BubbleBottomRight.png"
        }
    }

    var normalizedOrigin: (x: Int, y: Int) {
        switch self {
        case .topLeft: (clusterOrigin, canvasSize / 2)
        case .topRight: (canvasSize / 2, canvasSize / 2)
        case .bottomLeft: (clusterOrigin, clusterOrigin)
        case .bottomRight: (canvasSize / 2, clusterOrigin)
        }
    }

    func contains(x: Int, y: Int) -> Bool {
        let artworkInset = 72
        guard x >= artworkInset,
              x < canvasSize - artworkInset,
              y >= artworkInset,
              y < canvasSize - artworkInset else {
            return false
        }

        return switch self {
        case .topLeft: x < canvasSize / 2 && y >= canvasSize / 2
        case .topRight: x >= canvasSize / 2 && y >= canvasSize / 2
        case .bottomLeft: x < canvasSize / 2 && y < canvasSize / 2
        case .bottomRight: x >= canvasSize / 2 && y < canvasSize / 2
        }
    }
}

private func loadSourcePixels(from sourceURL: URL) throws -> [UInt8] {
    guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    var pixels = [UInt8](repeating: 0, count: canvasSize * bytesPerRow)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: canvasSize,
                  height: canvasSize,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        )
        return true
    }
    guard rendered else { throw CocoaError(.fileReadCorruptFile) }
    return pixels
}

private func bubbleAlpha(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
    let maximum = Double(max(red, max(green, blue))) / 255
    let minimum = Double(min(red, min(green, blue))) / 255
    guard maximum > 0 else { return 0 }

    let saturation = (maximum - minimum) / maximum
    let normalized = min(1, max(0, (saturation - 0.12) / 0.12))
    let eased = normalized * normalized * (3 - 2 * normalized)
    return UInt8((eased * 255).rounded())
}

private struct PixelBounds {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private func alphaBounds(in pixels: [UInt8]) -> PixelBounds? {
    var minX = canvasSize
    var minY = canvasSize
    var maxX = -1
    var maxY = -1

    for y in 0..<canvasSize {
        for x in 0..<canvasSize {
            let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
            guard alpha > 12 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

private func normalizedPixels(
    from pixels: [UInt8],
    bounds: PixelBounds,
    for bubble: Bubble
) -> [UInt8] {
    var normalized = [UInt8](repeating: 0, count: pixels.count)
    let origin = bubble.normalizedOrigin
    let sourceWidth = Double(max(1, bounds.width - 1))
    let sourceHeight = Double(max(1, bounds.height - 1))
    let targetSpan = Double(normalizedBubbleSize - 1)

    for targetY in 0..<normalizedBubbleSize {
        let sourceY = Double(bounds.minY) + Double(targetY) * sourceHeight / targetSpan
        let y0 = Int(sourceY.rounded(.down))
        let y1 = min(bounds.maxY, y0 + 1)
        let yFraction = sourceY - Double(y0)

        for targetX in 0..<normalizedBubbleSize {
            let sourceX = Double(bounds.minX) + Double(targetX) * sourceWidth / targetSpan
            let x0 = Int(sourceX.rounded(.down))
            let x1 = min(bounds.maxX, x0 + 1)
            let xFraction = sourceX - Double(x0)
            let destinationOffset = (origin.y + targetY) * bytesPerRow
                + (origin.x + targetX) * bytesPerPixel

            for channel in 0..<bytesPerPixel {
                let topLeft = Double(pixels[y0 * bytesPerRow + x0 * bytesPerPixel + channel])
                let topRight = Double(pixels[y0 * bytesPerRow + x1 * bytesPerPixel + channel])
                let bottomLeft = Double(pixels[y1 * bytesPerRow + x0 * bytesPerPixel + channel])
                let bottomRight = Double(pixels[y1 * bytesPerRow + x1 * bytesPerPixel + channel])
                let top = topLeft + (topRight - topLeft) * xFraction
                let bottom = bottomLeft + (bottomRight - bottomLeft) * xFraction
                normalized[destinationOffset + channel] = UInt8(
                    (top + (bottom - top) * yFraction).rounded()
                )
            }
        }
    }

    return normalized
}

private func writeLayer(
    for bubble: Bubble,
    sourcePixels: [UInt8],
    to destinationURL: URL
) throws {
    var layerPixels = [UInt8](repeating: 0, count: sourcePixels.count)

    for y in 0..<canvasSize {
        for x in 0..<canvasSize where bubble.contains(x: x, y: y) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let red = sourcePixels[offset]
            let green = sourcePixels[offset + 1]
            let blue = sourcePixels[offset + 2]
            let alpha = bubbleAlpha(red: red, green: green, blue: blue)
            guard alpha > 0 else { continue }

            let alphaScale = Double(alpha) / 255
            layerPixels[offset] = UInt8((Double(red) * alphaScale).rounded())
            layerPixels[offset + 1] = UInt8((Double(green) * alphaScale).rounded())
            layerPixels[offset + 2] = UInt8((Double(blue) * alphaScale).rounded())
            layerPixels[offset + 3] = alpha
        }
    }

    guard let bounds = alphaBounds(in: layerPixels) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var outputPixels = normalizedPixels(from: layerPixels, bounds: bounds, for: bubble)

    let wroteImage = outputPixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: canvasSize,
                  height: canvasSize,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  destinationURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
    guard wroteImage else { throw CocoaError(.fileWriteUnknown) }
}

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = scriptDirectory.deletingLastPathComponent()
let sourceURL = repositoryRoot.appendingPathComponent("Resources/AppIconSource.png")
let assetsDirectory = repositoryRoot
    .appendingPathComponent("Resources/AppIcon.icon/Assets", isDirectory: true)

let sourcePixels = try loadSourcePixels(from: sourceURL)
for bubble in Bubble.allCases {
    try writeLayer(
        for: bubble,
        sourcePixels: sourcePixels,
        to: assetsDirectory.appendingPathComponent(bubble.filename)
    )
}

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

// 图片相关的平台差异（M28 首验之二十九）：`ImageLoader` / `CachedImage` 是跨端件，
// `swift test` 会在 macOS 上编 CatVodUI（那里没有 UIKit）—— 平台分叉只许出现在这里，
// 与 `PlatformShims` / `LayerHostView` 同一套约定（`docs/UI 规范.md` 第二节）。

#if os(iOS)
import UIKit

/// 跨端的图片类型：iOS 是 `UIImage`，macOS 是 `NSImage`。
typealias PlatformImage = UIImage

extension PlatformImage {
    var platformSize: CGSize {
        size
    }
}

/// 画一张纯色测试图（单测用；生产路径不经过它）。
func platformTestImage(size: CGSize, color: UIColor) -> PlatformImage? {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

/// 测试图的 PNG 数据。
func platformPNGData(_ image: PlatformImage) -> Data? {
    image.pngData()
}

/// SwiftUI 里画跨端图片。
struct PlatformImageView: View {
    let image: PlatformImage
    var contentMode: ContentMode

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }
}

#else
import AppKit

/// 跨端的图片类型：iOS 是 `UIImage`，macOS 是 `NSImage`。
typealias PlatformImage = NSImage

extension PlatformImage {
    var platformSize: CGSize {
        size
    }
}

/// 画一张纯色测试图（单测用；生产路径不经过它）。
func platformTestImage(size: CGSize, color: NSColor) -> PlatformImage? {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
}

/// 测试图的 PNG 数据。
func platformPNGData(_ image: PlatformImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

/// SwiftUI 里画跨端图片。
struct PlatformImageView: View {
    let image: PlatformImage
    var contentMode: ContentMode

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }
}
#endif

/// 不解码全图，直接按目标尺寸取缩略图（`ImageIO` 在后台线程做，两端同一份）。
/// 数据不是图片（HTML 错误页、防盗链占位）时给 nil，由调用方翻成自己的错误。
func platformDownsample(_ data: Data, to size: CGSize) -> PlatformImage? {
    let maxPixel = max(size.width, size.height)
    guard maxPixel > 1,
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    #if os(iOS)
    return UIImage(cgImage: cgImage)
    #else
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #endif
}

import AppKit
import Foundation
import ImageIO
@preconcurrency import QuickLookUI

@MainActor
final class CaptureFilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = CaptureFilePreview()
    private var fileURL: URL?

    static func thumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: false,
                  ] as CFDictionary
              )
        else {
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }

    func show(_ url: URL) {
        fileURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { fileURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { fileURL as NSURL? }
    }
}

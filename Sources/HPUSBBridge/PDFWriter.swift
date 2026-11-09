// SPDX-License-Identifier: GPL-3.0-or-later
//
// Combines scanned JPEG pages into a single PDF using CoreGraphics.

import CoreGraphics
import Foundation
import ImageIO

public enum PDFWriterError: Error, CustomStringConvertible {
    case badImage(Int)
    case cannotCreate(String)

    public var description: String {
        switch self {
        case let .badImage(i): return "Page \(i + 1) is not a readable image."
        case let .cannotCreate(path): return "Cannot create PDF at \(path)."
        }
    }
}

public enum PDFWriter {
    /// Writes `pages` (JPEG data) to `url`, sizing each PDF page from the image's DPI.
    public static func write(pages: [Data], dpi: Int, to url: URL) throws {
        try write(pages: pages.map { ($0, dpi) }, to: url)
    }

    /// Writes pages that may have been scanned at different resolutions.
    public static func write(pages: [(jpeg: Data, dpi: Int)], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFWriterError.cannotCreate(url.path) }

        for (index, (data, dpi)) in pages.enumerated() {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw PDFWriterError.badImage(index) }
            let scale = 72.0 / Double(max(dpi, 1))
            var box = CGRect(x: 0, y: 0,
                             width: Double(image.width) * scale,
                             height: Double(image.height) * scale)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }
}

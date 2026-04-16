#!/usr/bin/env swift
import Foundation
import PDFKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Config {
    var input: String = ""
    var output: String = ""
    var dpi: Double = 180
    var jpegQuality: Double = 0.78
    var grayscale: Bool = false
    var maxPages: Int? = nil
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

func printUsage() {
    let text = """
    Usage:
      compress_pdf.swift --input <file.pdf> --output <compressed.pdf> [--dpi 180] [--jpeg-quality 0.78] [--grayscale] [--max-pages N]

    Notes:
      - Creates a new image-based PDF by rasterizing each page and rebuilding it.
      - Best for design-heavy PDFs, portfolios, decks, and image-heavy exports.
      - Not ideal when selectable text, OCR, or editability must be preserved.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func parseArgs() throws -> Config {
    var cfg = Config()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--input", "-i":
            i += 1; guard i < args.count else { throw CLIError.message("Missing value for \(arg)") }
            cfg.input = args[i]
        case "--output", "-o":
            i += 1; guard i < args.count else { throw CLIError.message("Missing value for \(arg)") }
            cfg.output = args[i]
        case "--dpi":
            i += 1; guard i < args.count, let v = Double(args[i]), v > 0 else { throw CLIError.message("Invalid --dpi value") }
            cfg.dpi = v
        case "--jpeg-quality":
            i += 1; guard i < args.count, let v = Double(args[i]), v >= 0.1, v <= 1.0 else { throw CLIError.message("Invalid --jpeg-quality value; expected 0.1-1.0") }
            cfg.jpegQuality = v
        case "--grayscale":
            cfg.grayscale = true
        case "--max-pages":
            i += 1; guard i < args.count, let v = Int(args[i]), v > 0 else { throw CLIError.message("Invalid --max-pages value") }
            cfg.maxPages = v
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw CLIError.message("Unknown argument: \(arg)")
        }
        i += 1
    }
    guard !cfg.input.isEmpty else { throw CLIError.message("Missing --input") }
    guard !cfg.output.isEmpty else { throw CLIError.message("Missing --output") }
    return cfg
}

func fileSize(_ path: String) -> UInt64? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return attrs?[.size] as? UInt64
}

func humanBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024 && idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    return String(format: idx == 0 ? "%.0f %@" : "%.2f %@", value, units[idx])
}

func jpegData(from image: NSImage, quality: Double, grayscale: Bool) throws -> Data {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        throw CLIError.message("Failed to create bitmap representation")
    }

    var rep = bitmap
    if grayscale {
        guard let grayRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CLIError.message("Failed to create grayscale bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: grayRep) else {
            throw CLIError.message("Failed to create grayscale graphics context")
        }
        NSGraphicsContext.current = ctx
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: grayRep.pixelsWide, height: grayRep.pixelsHigh).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: grayRep.pixelsWide, height: grayRep.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        rep = grayRep
    }

    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
        throw CLIError.message("Failed to encode JPEG data")
    }
    return data
}

func imageFromPDFPage(_ page: PDFPage, dpi: Double) throws -> NSImage {
    let pageRect = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let pixelWidth = max(1, Int((pageRect.width * scale).rounded(.up)))
    let pixelHeight = max(1, Int((pageRect.height * scale).rounded(.up)))

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CLIError.message("Failed to create bitmap canvas")
    }

    rep.size = NSSize(width: pageRect.width, height: pageRect.height)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw CLIError.message("Failed to create graphics context")
    }
    NSGraphicsContext.current = ctx
    ctx.cgContext.setFillColor(NSColor.white.cgColor)
    ctx.cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.cgContext.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: pageRect.width, height: pageRect.height))
    image.addRepresentation(rep)
    return image
}

func drawJPEGPage(_ imageData: Data, into context: CGContext, mediaBox: CGRect) throws {
    guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CLIError.message("Failed to decode JPEG page image")
    }

    context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
    context.interpolationQuality = .high
    context.setFillColor(NSColor.white.cgColor)
    context.fill(mediaBox)
    context.draw(cgImage, in: mediaBox)
    context.endPDFPage()
}

func main() throws {
    let cfg = try parseArgs()
    let inputURL = URL(fileURLWithPath: cfg.input)
    let outputURL = URL(fileURLWithPath: cfg.output)

    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        throw CLIError.message("Input file not found: \(inputURL.path)")
    }
    if inputURL.standardizedFileURL == outputURL.standardizedFileURL {
        throw CLIError.message("Refusing to overwrite input file; choose a different --output path")
    }

    guard let pdf = PDFDocument(url: inputURL) else {
        throw CLIError.message("Unable to open PDF: \(inputURL.path)")
    }
    let totalPages = pdf.pageCount
    if totalPages == 0 {
        throw CLIError.message("Input PDF has no pages")
    }

    let pagesToProcess = min(totalPages, cfg.maxPages ?? totalPages)
    let parentDir = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
        throw CLIError.message("Unable to create output file: \(outputURL.path)")
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CLIError.message("Unable to create PDF context")
    }

    for idx in 0..<pagesToProcess {
        guard let page = pdf.page(at: idx) else {
            throw CLIError.message("Missing page at index \(idx)")
        }
        let bounds = page.bounds(for: .mediaBox)
        let rendered = try imageFromPDFPage(page, dpi: cfg.dpi)
        let jpeg = try jpegData(from: rendered, quality: cfg.jpegQuality, grayscale: cfg.grayscale)
        try drawJPEGPage(jpeg, into: pdfContext, mediaBox: bounds)
        FileHandle.standardError.write(Data("Rendered page \(idx + 1)/\(pagesToProcess)\n".utf8))
    }

    pdfContext.closePDF()

    let original = fileSize(inputURL.path)
    let compressed = fileSize(outputURL.path)
    let ratio: String
    if let o = original, let c = compressed, o > 0 {
        ratio = String(format: "%.1f%%", (1.0 - (Double(c) / Double(o))) * 100.0)
    } else {
        ratio = "unknown"
    }

    let summary = """
    Done.
    Input:  \(inputURL.path)
    Output: \(outputURL.path)
    Pages:  \(pagesToProcess)/\(totalPages)
    DPI:    \(Int(cfg.dpi.rounded()))
    JPEG:   \(String(format: "%.2f", cfg.jpegQuality))
    Gray:   \(cfg.grayscale ? "yes" : "no")
    Original size:   \(original.map(humanBytes) ?? "unknown")
    Compressed size: \(compressed.map(humanBytes) ?? "unknown")
    Reduction:       \(ratio)
    Text selectable: no (image-based rebuild)
    """
    print(summary)
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data(("Error: \(error)\n").utf8))
    printUsage()
    exit(1)
}

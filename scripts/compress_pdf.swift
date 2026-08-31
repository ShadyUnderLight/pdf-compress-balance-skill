#!/usr/bin/env swift
import Foundation
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
    var targetMB: Double? = nil
    var maxAttempts: Int = 5
}

struct AttemptResult {
    let path: String
    let dpi: Double
    let jpegQuality: Double
    let sizeBytes: UInt64
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
      compress_pdf.swift --input <file.pdf> --output <compressed.pdf> --target-mb 20 [--max-attempts 5] [--grayscale] [--max-pages N]

    Notes:
      - Creates a new image-based PDF by rasterizing each page and rebuilding it.
      - Best for design-heavy PDFs, portfolios, decks, and image-heavy exports.
      - Not ideal when selectable text, OCR, or editability must be preserved.
      - With --target-mb, the script automatically tries a few parameter combinations and keeps the closest result.
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
        case "--target-mb":
            i += 1; guard i < args.count, let v = Double(args[i]), v > 0 else { throw CLIError.message("Invalid --target-mb value") }
            cfg.targetMB = v
        case "--max-attempts":
            i += 1; guard i < args.count, let v = Int(args[i]), v > 0, v <= 12 else { throw CLIError.message("Invalid --max-attempts value; expected 1-12") }
            cfg.maxAttempts = v
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

func humanMB(_ bytes: UInt64) -> Double {
    Double(bytes) / 1024.0 / 1024.0
}

func normalizedMediaBox(for page: CGPDFPage) -> CGRect {
    let box = page.getBoxRect(.mediaBox)
    return CGRect(origin: .zero, size: box.size)
}

func renderPDFPage(_ page: CGPDFPage, dpi: Double) throws -> CGImage {
    let mediaBox = page.getBoxRect(.mediaBox)
    guard mediaBox.width > 0, mediaBox.height > 0 else {
        throw CLIError.message("PDF page has invalid media box: \(mediaBox)")
    }

    let scale = dpi / 72.0
    let pixelWidth = max(1, Int((mediaBox.width * scale).rounded(.up)))
    let pixelHeight = max(1, Int((mediaBox.height * scale).rounded(.up)))

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw CLIError.message("Failed to create sRGB color space")
    }
    guard let ctx = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CLIError.message("Failed to create bitmap context")
    }

    let drawRect = CGRect(x: 0, y: 0, width: mediaBox.width, height: mediaBox.height)
    let transform = page.getDrawingTransform(.mediaBox, rect: drawRect, rotate: 0, preserveAspectRatio: true)

    ctx.setFillColor(gray: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(transform)
    ctx.drawPDFPage(page)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        throw CLIError.message("Failed to create CGImage from rendered page")
    }
    return image
}

func grayscaleImage(from image: CGImage) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else {
        throw CLIError.message("Failed to create grayscale color space")
    }
    guard let ctx = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
        throw CLIError.message("Failed to create grayscale bitmap context")
    }
    ctx.setFillColor(gray: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let gray = ctx.makeImage() else {
        throw CLIError.message("Failed to create grayscale image")
    }
    return gray
}

func jpegData(from image: CGImage, quality: Double, grayscale: Bool) throws -> Data {
    let finalImage = grayscale ? try grayscaleImage(from: image) : image
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CLIError.message("Failed to create JPEG destination")
    }
    let props: CFDictionary = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(dest, finalImage, props)
    guard CGImageDestinationFinalize(dest) else {
        throw CLIError.message("Failed to encode JPEG data")
    }
    return data as Data
}

func drawJPEGPage(_ imageData: Data, into context: CGContext, mediaBox: CGRect) throws {
    guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CLIError.message("Failed to decode JPEG page image")
    }

    let normalizedBox = CGRect(origin: .zero, size: mediaBox.size)
    context.beginPDFPage([kCGPDFContextMediaBox as String: normalizedBox] as CFDictionary)
    context.interpolationQuality = .high
    context.setFillColor(gray: 1.0, alpha: 1.0)
    context.fill(normalizedBox)
    context.draw(cgImage, in: normalizedBox)
    context.endPDFPage()
}

func compressPDF(inputURL: URL, outputURL: URL, dpi: Double, jpegQuality: Double, grayscale: Bool, maxPages: Int?) throws {
    guard let provider = CGDataProvider(url: inputURL as CFURL),
          let pdf = CGPDFDocument(provider) else {
        throw CLIError.message("Unable to open PDF: \(inputURL.path)")
    }
    let totalPages = pdf.numberOfPages
    if totalPages == 0 {
        throw CLIError.message("Input PDF has no pages")
    }

    let pagesToProcess = min(totalPages, maxPages ?? totalPages)
    let parentDir = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
        throw CLIError.message("Unable to create output file: \(outputURL.path)")
    }
    guard let firstPage = pdf.page(at: 1) else {
        throw CLIError.message("Missing first page")
    }
    var initialBox = normalizedMediaBox(for: firstPage)
    guard let pdfContext = CGContext(consumer: consumer, mediaBox: &initialBox, nil) else {
        throw CLIError.message("Unable to create PDF context")
    }

    for idx in 1...pagesToProcess {
        guard let page = pdf.page(at: idx) else {
            throw CLIError.message("Missing page at index \(idx)")
        }
        let rendered = try renderPDFPage(page, dpi: dpi)
        let jpeg = try jpegData(from: rendered, quality: jpegQuality, grayscale: grayscale)
        try drawJPEGPage(jpeg, into: pdfContext, mediaBox: normalizedMediaBox(for: page))
        FileHandle.standardError.write(Data("Rendered page \(idx)/\(pagesToProcess) [dpi=\(Int(dpi.rounded())) q=\(String(format: "%.2f", jpegQuality))]\n".utf8))
    }

    pdfContext.closePDF()
}

func candidatePairs(seedDPI: Double, seedQuality: Double) -> [(Double, Double)] {
    let candidates: [(Double, Double)] = [
        (seedDPI, seedQuality),
        (max(120, seedDPI - 10), max(0.55, seedQuality - 0.03)),
        (max(120, seedDPI - 20), max(0.50, seedQuality - 0.06)),
        (max(120, seedDPI - 30), max(0.45, seedQuality - 0.08)),
        (seedDPI + 10, min(0.95, seedQuality + 0.03)),
        (seedDPI + 20, min(0.95, seedQuality + 0.05)),
        (max(120, seedDPI - 15), seedQuality),
        (seedDPI, max(0.50, seedQuality - 0.08)),
        (max(120, seedDPI - 25), min(0.95, seedQuality + 0.02)),
        (seedDPI + 5, max(0.50, seedQuality - 0.04))
    ]

    var seen = Set<String>()
    var unique: [(Double, Double)] = []
    for (dpi, q) in candidates {
        let normDPI = max(120, min(260, (dpi / 5.0).rounded() * 5.0))
        let normQ = max(0.45, min(0.95, (q * 100).rounded() / 100.0))
        let key = "\(Int(normDPI))|\(String(format: "%.2f", normQ))"
        if !seen.contains(key) {
            seen.insert(key)
            unique.append((normDPI, normQ))
        }
    }
    return unique
}

func autoCompress(cfg: Config, inputURL: URL, outputURL: URL) throws -> AttemptResult {
    let targetBytes = UInt64(cfg.targetMB! * 1024.0 * 1024.0)
    let fm = FileManager.default
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("papertrim-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    let candidates = Array(candidatePairs(seedDPI: cfg.dpi, seedQuality: cfg.jpegQuality).prefix(cfg.maxAttempts))
    var best: AttemptResult?

    for (index, pair) in candidates.enumerated() {
        let (dpi, quality) = pair
        let tempOut = tempRoot.appendingPathComponent("attempt-\(index + 1).pdf")
        try compressPDF(inputURL: inputURL, outputURL: tempOut, dpi: dpi, jpegQuality: quality, grayscale: cfg.grayscale, maxPages: cfg.maxPages)
        guard let size = fileSize(tempOut.path) else {
            throw CLIError.message("Failed to measure attempt output: \(tempOut.path)")
        }
        let result = AttemptResult(path: tempOut.path, dpi: dpi, jpegQuality: quality, sizeBytes: size)
        let delta = abs(Int64(size) - Int64(targetBytes))
        let qualityText = String(format: "%.2f", quality)
        let targetText = String(format: "%.2f", cfg.targetMB!)
        let attemptLog = "Attempt \(index + 1)/\(candidates.count): \(humanBytes(size)) at dpi=\(Int(dpi.rounded())) q=\(qualityText) target=\(targetText)MB\n"
        FileHandle.standardError.write(Data(attemptLog.utf8))

        if let currentBest = best {
            let bestDelta = abs(Int64(currentBest.sizeBytes) - Int64(targetBytes))
            if delta < bestDelta {
                best = result
            }
        } else {
            best = result
        }

        let ratio = Double(size) / Double(targetBytes)
        if ratio >= 0.92 && ratio <= 1.08 {
            best = result
            break
        }
    }

    guard let chosen = best else {
        throw CLIError.message("Automatic target-size search produced no result")
    }

    if fm.fileExists(atPath: outputURL.path) {
        try fm.removeItem(at: outputURL)
    }
    try fm.copyItem(at: URL(fileURLWithPath: chosen.path), to: outputURL)
    return AttemptResult(path: outputURL.path, dpi: chosen.dpi, jpegQuality: chosen.jpegQuality, sizeBytes: chosen.sizeBytes)
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

    let original = fileSize(inputURL.path)
    let finalResult: AttemptResult

    if cfg.targetMB != nil {
        finalResult = try autoCompress(cfg: cfg, inputURL: inputURL, outputURL: outputURL)
    } else {
        try compressPDF(inputURL: inputURL, outputURL: outputURL, dpi: cfg.dpi, jpegQuality: cfg.jpegQuality, grayscale: cfg.grayscale, maxPages: cfg.maxPages)
        guard let size = fileSize(outputURL.path) else {
            throw CLIError.message("Unable to measure output file: \(outputURL.path)")
        }
        finalResult = AttemptResult(path: outputURL.path, dpi: cfg.dpi, jpegQuality: cfg.jpegQuality, sizeBytes: size)
    }

    let ratio: String
    if let o = original, o > 0 {
        ratio = String(format: "%.1f%%", (1.0 - (Double(finalResult.sizeBytes) / Double(o))) * 100.0)
    } else {
        ratio = "unknown"
    }

    let targetLine: String
    if let targetMB = cfg.targetMB {
        let targetText = String(format: "%.2f", targetMB)
        let qualityText = String(format: "%.2f", finalResult.jpegQuality)
        targetLine = "Target: \(targetText) MB\nChosen: dpi=\(Int(finalResult.dpi.rounded())) jpeg=\(qualityText)\n"
    } else {
        targetLine = ""
    }

    let summary = """
    Done.
    Input:  \(inputURL.path)
    Output: \(outputURL.path)
    \(targetLine)Original size:   \(original.map(humanBytes) ?? "unknown")
    Compressed size: \(humanBytes(finalResult.sizeBytes))
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

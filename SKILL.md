---
name: pdf-compress-balance
description: Compress large PDFs for sharing while preserving good screen-reading quality, especially portfolios, slide exports, Canva/Figma/PowerPoint PDFs, decks, and other design-heavy or image-heavy PDFs. Use when a user wants a PDF reduced to a target size and can accept loss of vector text, searchability, or editability; first classify the PDF as text-first, design-heavy, or scanned, then choose lighter optimization or raster-rebuild accordingly.
---

# PDF Compress Balance

Compress PDFs for sharing quality, not source-master fidelity. Prefer the smallest method that still keeps pages clear at normal phone and laptop reading zoom.

## Workflow

### 1. Classify the PDF

Choose the method based on the document type.

#### Type A: text-first PDF
Examples:
- contracts
- reports exported from Word
- academic papers
- mostly text with simple charts

Prefer:
- lighter/object compression first
- avoid rasterizing unless the target cannot be met otherwise

Warn that rasterizing may weaken or remove:
- selectable text
- searchability
- editability
- very sharp high-zoom rendering

#### Type B: design-heavy PDF
Examples:
- portfolios
- visually styled resumes
- Canva exports
- Figma exports
- presentation decks
- posters
- image-heavy multi-page PDFs

Prefer:
- rasterizing each page
- rebuilding the PDF from page images

This is often far more effective than naive PDF recompression because it collapses heavy fonts, vectors, transparency, gradients, and layered objects into one image per page.

#### Type C: scanned PDF
Examples:
- scanned books
- scanned forms
- photographed documents

Prefer:
- downsampling
- careful JPEG compression
- optional grayscale if acceptable

### 2. Decide the strategy

Use this rule:
1. inspect page count, file size, and visual density
2. determine whether the user cares about sharing, print, or editability
3. if clearly design-heavy, use raster rebuild
4. if mostly text, try lighter optimization first
5. if scanned, downsample more aggressively and consider grayscale

Do not promise a very aggressive target without warning that visible quality loss may be required.

### 3. Use the bundled raster-rebuild script when appropriate

Best fit:
- portfolios
- resumes with strong visual layout
- pitch decks
- slide exports
- Canva/Figma/Keynote/PowerPoint PDFs
- image-heavy PDFs where appearance matters more than selectable text

Poor fit:
- legal documents
- research papers
- OCR/search-sensitive PDFs
- print-production files
- documents with dense tiny body text everywhere

Run from the skill directory:

```bash
swift scripts/compress_pdf.swift \
  --input /path/to/input.pdf \
  --output /path/to/input-compressed.pdf \
  --dpi 180 \
  --jpeg-quality 0.78
```

Useful presets:
- balanced default: `--dpi 180 --jpeg-quality 0.78`
- clearer but larger: `--dpi 200 --jpeg-quality 0.82`
- smaller but softer: `--dpi 150 --jpeg-quality 0.72`
- scanned sharing copy: `--dpi 150 --jpeg-quality 0.65 --grayscale`

If the result is still too large, adjust in this order:
1. 200 DPI -> 180 DPI
2. 180 DPI -> 150 DPI
3. reduce JPEG quality slightly
4. enable grayscale only if acceptable
5. go below 150 DPI only with explicit warning

Use `--max-pages N` only for quick tuning samples, not for the final delivery unless the user asked for a partial file.

### 4. Validate and report

Always report:
- original file size
- compressed file size
- compression ratio
- whether text is still selectable
- likely quality impact

If you used raster rebuild, say plainly that text is now image-based and extreme zoom or further editing will be worse than in the original.

## Bundled script behavior

`scripts/compress_pdf.swift`:
- rasterizes each page with PDFKit/AppKit
- encodes pages as JPEG
- rebuilds a new image-based PDF
- prints original size, output size, and reduction
- refuses to overwrite the input file

This script is macOS-oriented.

## Tradeoff language

Prefer wording like:

> I didn’t just squeeze the original PDF. I flattened each page into a high-enough image and rebuilt the PDF. That removes heavy font, vector, transparency, and layered-object overhead while keeping normal viewing quality strong.

Short version:

> I compressed this PDF by flattening each page into a high-enough image and rebuilding it at a balanced resolution. That works much better for portfolios and design exports than ordinary PDF recompression, because it removes font, vector, transparency, and layered-object overhead. The result keeps strong screen-reading quality while greatly reducing size. The main tradeoff is that text is no longer preserved as vector text, so extreme zoom and further editing are worse than in the original.

## Safety rules

- Never overwrite the original file unless explicitly requested.
- Always produce a new output file.
- If the user wants both strong compression and editability, warn that those goals conflict.
- If the requested target is very aggressive, warn that readability may degrade.
- If the source is already optimized, say the target may not be reachable without visible loss.
- If the compressed output becomes larger than the input, say so plainly; this usually means raster rebuild was the wrong method for that file.

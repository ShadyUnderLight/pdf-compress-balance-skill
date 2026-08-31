# PaperTrim

**Smart PDF compression for screen-first sharing.**

PaperTrim is a PDF compression toolkit that balances file size and screen readability. It is designed for the PDFs that ordinary compressors struggle with — portfolios, slide decks, and other design-heavy exports from Canva, Figma, PowerPoint, and Keynote.

Ordinary PDF recompression tweaks embedded streams and objects. For design-heavy PDFs that contain many fonts, vector shapes, transparencies, shadows, gradients, and layered page structures, that approach often saves little. PaperTrim takes a different route: it classifies the PDF first, then chooses a compression strategy that matches the document type.

---

## Why PaperTrim

Many large PDFs look simple but are expensive to store:

- embedded fonts
- vector objects and layered elements
- transparency, shadows, and gradients
- high-resolution placed images repeated across pages

Standard object-level recompression preserves the full structure but removes little of this overhead. For design-heavy documents the dominant cost is the structure itself.

PaperTrim addresses this by optionally rasterizing each page at a balanced DPI and rebuilding the PDF from JPEG-encoded page images. This collapses font, vector, and layer overhead into one image per page, which often yields significantly smaller files while keeping normal screen reading quality strong.

PaperTrim does not apply raster-rebuild blindly. It classifies first.

## How it works

```
Classify → Choose strategy → Compress → Compare result
```

1. **Classify** the PDF as text-first, design-heavy, or scanned.
2. **Choose strategy** — lighter optimization for text-first documents, raster-rebuild for design-heavy/scanned when appropriate.
3. **Compress** with the bundled Swift script (PDFKit + AppKit) or another suitable tool.
4. **Compare result** — report original size, compressed size, reduction, and quality tradeoff. If the result is larger, PaperTrim says so explicitly.

## PDF types

### Type A: text-first

Contracts, academic papers, reports exported from Word, and other documents that are mostly text with simple charts.

Preference: try lighter/object-level compression first. Avoid rasterization unless the size target cannot be met otherwise, since rasterization removes selectable text and sharp vector rendering at high zoom.

### Type B: design-heavy

Portfolios, case studies, visually styled resumes, posters, Canva/Figma exports, and presentation decks from PowerPoint/Keynote. Includes other image-heavy, visually dense multi-page PDFs.

Preference: rasterize each page and rebuild from page images. This is usually far more effective than naive recompression for this category.

### Type C: scanned

Scanned books, scanned forms, and photographed documents.

Preference: downsample, apply careful JPEG compression, and consider grayscale if acceptable.

## Best for

- portfolios
- presentation decks
- Canva / Figma exports
- design-heavy resumes
- case studies
- image-heavy PDFs
- PDFs intended for email, upload, or screen sharing

## Not recommended for

- legal documents
- academic papers requiring selectable/searchable text
- editable master files
- print masters
- documents where OCR/searchability must remain intact

## Included tools

- **Agent skill instructions** (`SKILL.md`) — classification rules, strategy selection, presets, and safety guidance for automation
- **Packaged skill file** (`papertrim.skill`) — distributable bundle containing the skill and script
- **macOS-oriented Swift compression script** (`scripts/compress_pdf.swift`) — runnable raster-rebuild workflow
- **PDFKit / AppKit based workflow** — renders each page, encodes as JPEG, and rebuilds a new image-based PDF; reports sizes and refuses to overwrite the original

Structure:

```text
.
├── README.md              # project overview (this file)
├── SKILL.md               # agent skill instructions
├── papertrim.skill        # packaged distributable
└── scripts/
    └── compress_pdf.swift # Swift raster-rebuild script
```

## Usage

### As an agent skill

If your environment supports skill packages, use `papertrim.skill` directly.

### Run the script

Requires macOS with Swift toolchain (uses PDFKit and AppKit).

```bash
swift scripts/compress_pdf.swift \
  --input /path/to/input.pdf \
  --output /path/to/input-compressed.pdf \
  --dpi 180 \
  --jpeg-quality 0.78
```

With a target size, let the script search automatically:

```bash
swift scripts/compress_pdf.swift \
  --input /path/to/input.pdf \
  --output /path/to/input-compressed.pdf \
  --target-mb 20
```

Presets:

- **Balanced (default):** `--dpi 180 --jpeg-quality 0.78`
- **Higher quality:** `--dpi 200 --jpeg-quality 0.82`
- **Smaller size:** `--dpi 150 --jpeg-quality 0.72`
- **Scanned sharing:** `--dpi 150 --jpeg-quality 0.65 --grayscale`

Additional options:

- `--grayscale` — convert pages to grayscale
- `--max-pages N` — process only the first N pages (useful for quick tuning samples, not for final delivery)
- `--target-mb` with `--max-attempts` — auto-tries parameter combinations toward the target

## Compression strategy

If the initial result is still too large, adjust in this order:

1. 200 DPI → 180 DPI
2. 180 DPI → 150 DPI
3. reduce JPEG quality slightly
4. enable grayscale only if acceptable
5. going below 150 DPI requires explicit warning — readability may degrade noticeably

Do not promise an aggressive target without warning about visible quality loss.

## Tradeoff

PaperTrim optimizes for:

> **looks close to the original, but much smaller**

Not for:

> **preserve the complete editable/vector structure**

Concretely:

- text may lose its original vector/text layer and become image-based
- search, copy, and text selection may no longer work
- extreme zoom will look softer than the original vector PDF
- the result is not suitable as an editable source, print master, legal record, or any document where OCR/searchability must be preserved

PaperTrim makes this tradeoff explicit when it uses raster-rebuild and reports whether text remains selectable.

## Safety

- Never overwrite the original PDF by default — always write to a new file. The script refuses to use the same path for input and output.
- If the compressed output is larger than the input, report it plainly. This usually means raster-rebuild was the wrong method for that file.
- If a target size is extremely aggressive, warn that readability will degrade.
- Goals like "very small + fully editable + fully searchable + high fidelity" may conflict — call out the conflict when it arises.
- If the source is already well-optimized, say the target may not be reachable without visible loss.

## License

MIT

# Capability coverage

Generated from [`coverage.json`](coverage.json) by `scripts/coverage.py`; CI fails if it is stale or if the catalog and this matrix disagree.
The baseline is Hokusai 2.2.2 (see `recipes/Package.swift`). Future operators tracked in ivantokar/hokusai#150 are not listed as promises.

Status: **implemented** works in the demo today; **partial** works with the limits named; **planned** is demo work that is not built yet (it does not mean the library lacks it).

39 implemented, 5 partial, 15 planned, 59 in total.


## Sources

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Encoded data | `Hokusai(data:)` | implemented | Web: upload, samples. |
| File URLs | `Hokusai(url:)` | partial | Generated Swift shows it with an input.jpg placeholder; macOS app will open files. The Web demo never reads server paths. |
| Streamed / spooled input | `Hokusai(spooling:)` | partial | Minimal route in both servers uses it; Runtime Lab shows the size limit and a streamed response. |
| Generated text as a source | `Hokusai.text(_:layout:style:)` | planned | Composition view. |
| Raw pixels | `Hokusai(raw:)` | implemented | Inspect > Raw pixels (raw input). |

## Geometry

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Auto-orient | `autoOrient()` | implemented | Playground. |
| Resize with fit, position, kernel | `resize(...)` | implemented | Playground. |
| Rotate | `rotate(by:)` | implemented | Playground. |
| Flip (vertical) | `flip(), flop()` | implemented | Playground. |
| Flop (horizontal) | `flop()` | implemented | Playground. |
| Crop (extract) | `extract(x:y:width:height:)` | implemented | Playground: on-canvas rectangle with handles, keyboard and numeric entry, fixed aspect ratios; edited on the image entering the step. |
| Smart crop | `smartCrop(width:height:strategy:)` | implemented | Playground. |
| Extend (canvas) | `extend(...)` | planned | Playground. |
| Affine | `affine(...)` | planned | Playground. |
| Trim | `trim(...)` | planned | Playground. |

## Effects

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Blur | `blur(sigma:precision:minAmplitude:)` | implemented | Playground. |
| Sharpen | `sharpen(sigma:)` | implemented | Playground. |
| Grayscale | `grayscale()` | implemented | Playground. |
| Tint | `tint(_:)` | implemented | Playground. |
| Normalize | `normalize(lower:upper:)` | implemented | Playground. |
| CLAHE | `clahe(width:height:maxSlope:)` | implemented | Playground. |
| Gamma | `gamma(_:)` | implemented | Playground. |
| Negate | `negate(alpha:)` | implemented | Playground. |
| Median | `median(size:)` | implemented | Playground. |
| Threshold | `threshold(_:grayscale:)` | implemented | Playground. |
| Modulate | `modulate(brightness:saturation:hue:)` | implemented | Playground. |
| Linear | `linear(multiply:add:)` | planned | Playground. |

## Advanced pixels

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Convolution kernels | `convolve(_:)` | planned | Playground. |
| Colour matrices | `recombine(_:)` | planned | Playground. |
| Dilate / erode | `dilate(radius:), erode(radius:)` | planned | Playground. |
| Edge detectors | `edges(_:)` | planned | Playground. |
| Channel extraction | `extractChannel(_:)` | planned | Playground. |
| Alpha from a mask | `joinAlpha(_:)` | planned | Playground (needs a second image asset for masks). |

## Colour and alpha

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Colour-space conversion | `convert(to:)` | planned | Playground. |
| Ensure alpha | `ensureAlpha(opacity:)` | planned | Playground. |
| Remove alpha | `removeAlpha()` | planned | Playground. |
| Flatten | `flatten(background:)` | implemented | Playground. |

## Composition and text

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Text overlay | `drawText(_:placement:layout:style:)` | partial | Playground: content, size, font, colour, gravity, offsets; layout, stroke, shadow planned. |
| Image layers, blend, opacity, compositing space | `composite(_:space:)` | planned | Playground (needs extra image assets). |

## Encoders

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| JPEG | `jpeg(quality:progressive:)` | implemented | Playground output panel with common and advanced typed options; Export / PDF view compares all encoders on real bytes. |
| PNG | `png(compressionLevel:interlaced:)` | implemented | Playground output panel with common and advanced typed options; Export / PDF view compares all encoders on real bytes. |
| WebP | `webp(quality:effort:lossless:)` | implemented | Playground output panel with common and advanced typed options; Export / PDF view compares all encoders on real bytes. |
| AVIF | `avif(quality:effort:lossless:)` | implemented | Playground output panel with common and advanced typed options; Export / PDF view compares all encoders on real bytes. |
| TIFF | `tiff(compression:)` | partial | Playground output panel (compression); Export / PDF view comparison. |
| GIF | `gif()` | implemented | Playground output panel; Export / PDF view comparison. |
| HEIF | `heif(options:)` | implemented | Playground output panel (HEVC or AV1, quality, effort, lossless); listed as unavailable with the reason when this libvips has no encoder; a labelled PNG proxy is shown because browsers do not display it. |
| Raster PDF | `pdf(pageSize:margins:background:)` | implemented | Playground output panel and the Raster PDF report card: page size, orientation, margins, position, background, effective-resolution cap, document properties; preview is page 1 decoded from the real PDF. |

## Metadata

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Source inspection | `metadata()` | implemented | Inspect view: dimensions, orientation, pixel model, density, pages, animation and embedded-block sizes. |
| Output metadata retention | `metadataPolicy(_:)` | implemented | Output panel (granular keep EXIF/ICC/XMP/IPTC/other/orientation/density) and Inspect view, verified on the exported bytes. |

## Raw and pages

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Raw input and output | `Hokusai(raw:), raw(...)` | implemented | Inspect > Raw pixels: output in every raw format with layout, stride, alpha convention, channel previews and pixel values from the real bytes; input from a generated grid with padded rows, premultiplied alpha, and refused wrong declarations. |
| Page selection and counts | `InputOptions.page` | implemented | Inspect > Pages: page and frame selector (zero-based API index), thumbnails, page count versus animation, frame delays and loop count; the selection applies to preview, inspection and export. |

## Vector PDF

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| HokusaiPDF documents | `VectorDocument, VectorPage` | implemented | Export / PDF view: multi-page document builder with text and Pango markup, rectangles, lines, gradients, images, page sizes and document properties; selectable text verified with a PDF reader in the tests. Not an editor for existing PDFs; no tables or other layout beyond what HokusaiPDF draws. |

## Terminals and runtime

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| data() | `data()` | implemented | Every render. |
| write(to:) | `write(to:)` | partial | Shown in the generated Swift; the demo returns bytes instead of writing server files. |
| Chunk streaming | `writeChunks(...), response()` | implemented | Minimal route in both servers streams with response(); Runtime Lab measures first byte and chunks per format. |
| Runtime capabilities | `Hokusai.capabilities()` | implemented | GET /api/capabilities. |
| Startup configuration | `Hokusai.configure(_:)` | implemented | Both servers configure at startup (HOKUSAI_MAX_CONCURRENT, HOKUSAI_MAX_QUEUED); Runtime Lab shows it read-only. |
| Scheduler status | `Hokusai.runtimeStatus` | implemented | GET /api/status. |
| Cancellation, limits, queue behaviour | `InputOptions.limits, RuntimeConfiguration` | implemented | Runtime Lab: cancel and observe the server's own status, a bounded burst against the queue, failure examples. |

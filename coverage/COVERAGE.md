# Capability coverage

Generated from [`coverage.json`](coverage.json) by `scripts/coverage.py`; CI fails if it is stale or if the catalog and this matrix disagree.
The baseline is Hokusai 2.2.2 (see `recipes/Package.swift`). Future operators tracked in ivantokar/hokusai#150 are not listed as promises.

Status: **implemented** works in the demo today; **partial** works with the limits named; **planned** is demo work that is not built yet (it does not mean the library lacks it).

25 implemented, 11 partial, 23 planned, 59 in total.


## Sources

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Encoded data | `Hokusai(data:)` | implemented | Web: upload, samples. |
| File URLs | `Hokusai(url:)` | partial | Generated Swift shows it with an input.jpg placeholder; macOS app will open files. The Web demo never reads server paths. |
| Streamed / spooled input | `Hokusai(spooling:)` | partial | Minimal route in both servers uses it; Runtime Lab planned. |
| Generated text as a source | `Hokusai.text(_:layout:style:)` | planned | Composition view. |
| Raw pixels | `Hokusai(raw:)` | planned | Inspect lab. |

## Geometry

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Auto-orient | `autoOrient()` | implemented | Playground. |
| Resize with fit, position, kernel | `resize(...)` | implemented | Playground. |
| Rotate | `rotate(by:)` | implemented | Playground. |
| Flip (vertical) | `flip(), flop()` | implemented | Playground. |
| Flop (horizontal) | `flop()` | implemented | Playground. |
| Crop (extract) | `extract(x:y:width:height:)` | partial | Playground: numeric rectangle; on-canvas crop planned. |
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
| JPEG | `jpeg(quality:progressive:)` | partial | Playground output panel; advanced typed options planned. |
| PNG | `png(compressionLevel:interlaced:)` | partial | Playground output panel; advanced typed options planned. |
| WebP | `webp(quality:effort:lossless:)` | partial | Playground output panel; advanced typed options planned. |
| AVIF | `avif(quality:effort:lossless:)` | partial | Playground output panel; advanced typed options planned. |
| TIFF | `tiff(compression:)` | partial | Playground output panel; advanced typed options planned. |
| GIF | `gif()` | implemented | Playground output panel. |
| HEIF | `heif(...)` | planned | Export / PDF view (needs a libvips with HEIF encoding; reported by /api/capabilities). |
| Raster PDF | `pdf(pageSize:margins:background:)` | planned | Export / PDF view. |

## Metadata

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Source inspection | `metadata()` | partial | Upload response shows dimensions, oriented size and format; full Inspect lab planned. |
| Output metadata retention | `metadata(_:)` | planned | Export / PDF view, verified on the exported bytes. |

## Raw and pages

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| Raw input and output | `Hokusai(raw:), raw(...)` | planned | Inspect lab. |
| Page selection and counts | `InputOptions.page` | planned | Inspect lab. |

## Vector PDF

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| HokusaiPDF documents | `PDFDocument` | planned | Export / PDF view. |

## Terminals and runtime

| Capability | Public API | Status | Where |
| --- | --- | --- | --- |
| data() | `data()` | implemented | Every render. |
| write(to:) | `write(to:)` | partial | Shown in the generated Swift; the demo returns bytes instead of writing server files. |
| Chunk streaming | `writeChunks(...), response()` | implemented | Minimal route in both servers streams with response(). |
| Runtime capabilities | `Hokusai.capabilities()` | implemented | GET /api/capabilities. |
| Startup configuration | `Hokusai.configure(_:)` | implemented | Both servers configure at startup; read-only display planned. |
| Scheduler status | `Hokusai.runtimeStatus` | implemented | GET /api/status. |
| Cancellation, limits, queue behaviour | `InputOptions.limits, RuntimeConfiguration` | planned | Runtime Lab. |

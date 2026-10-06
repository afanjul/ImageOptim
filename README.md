# ImageOptim 2.0 ⚡

<p align="center">
  <img src="imageoptim/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="160" height="160" alt="ImageOptim 2.0 Icon" />
</p>

<p align="center">
  <b>The modern, high-performance community super-fork of ImageOptim for macOS.</b><br/>
  Rewritten natively in <b>Swift 6</b> & <b>SwiftUI</b>, tuned for <b>Apple Silicon Performance Cores</b>, with full support for <b>Next-Gen Formats</b> (WebP, AVIF, JPEG XL, HEIC) and customizable export workflows.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.1.0-blue.svg" alt="Version 2.1.0" />
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-black.svg" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon%20%7C%20Intel-orange.svg" alt="Architecture" />
  <img src="https://img.shields.io/badge/swift-6.0-F05138.svg" alt="Swift 6" />
  <img src="https://img.shields.io/badge/ui-SwiftUI-007AFF.svg" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/license-GPL%20v2%2B-green.svg" alt="GPL v2+" />
</p>

---

## 🌟 What is ImageOptim 2.0?

**ImageOptim 2.0** is the unified evolution of the classic macOS image compression tool created by Kornel Lesiński. This release synthesizes the best innovations, architectural rewrites, and features from across the ImageOptim open-source community into a single, cohesive, modern application:

* **Swift 6 & SwiftUI Rewrite**: Completely rebuilt from the ground up to replace legacy Objective-C and AppKit with Swift actors, strict concurrency, and sleek native macOS Sonoma & Sequoia UI.
* **Apple Silicon Performance Core Prioritization**: Intelligently detects M-series performance cores (`hw.perflevel0.logicalcpu`) and dispatches optimization tasks with `.userInitiated` QoS to prevent macOS from throttling intensive batch compression onto low-power Efficiency cores.
* **Next-Generation Formats**: Native support for **WebP**, **AVIF**, **JPEG XL (`.jxl`)**, and hardware-accelerated **HEIC/HEIF-to-JPEG** conversion.
* **Custom Output & Export Workflows**: Preserve your originals or overwrite in place, export to custom destination directories, and apply filename prefixes/suffixes with dynamic date tokens (`{date}`, `{date:yyyy-MM-dd}`).
* **Interactive Queue & Statistics**: Filter queue items in real-time (`All`, `Active`, `Done`, `Failed`), trigger one-click retries, and view live multi-selection byte savings.
* **GPU-Accelerated Butteraugli**: Patched Google Guetzli to utilize Apple Silicon GPU acceleration for perceptual metric calculations.

> **Ported, integrated, and maintained by [afanjul](https://github.com/afanjul)** based on community contributions from Kornel Lesiński, wokenlex, SharkyRawr, tietjinator, a-j-n, HoobenWang, and others.

---

## 🚀 Key Features & Innovations

### 1. Unified Next-Gen Format Support
| Format | Engines / Workers | Optimization Capabilities |
| :--- | :--- | :--- |
| **PNG** | OxiPNG, AdvPNG, Zopfli, PNGCrush, pngquant | Lossless chunk stripping, filter heuristic optimization, exhaustive DEFLATE, and optional perceptual lossy quantization. |
| **JPEG** | Jpegli, MozJPEG, JPEGOptim, Jpegtran, Guetzli | Google perceptual quantization (Jpegli), Trellis quantization, progressive scan optimization, lossless metadata stripping, Butteraugli. |
| **WebP** | cwebp | Native Google WebP lossless compression and metadata hygiene. |
| **AVIF** | avifoptim / avifenc | High-efficiency AV1 image compression with lossless chroma subsampling preservation. |
| **JPEG XL** | jxloptim / cjxl | Next-generation `.jxl` lossless modular recompression and density reduction. |
| **HEIC / HEIF** | Apple ImageIO Hardware Pipeline | Automatic hardware-accelerated decoding of iOS camera captures into web-ready optimized JPEG. |
| **GIF** | Gifsicle | Animated GIF optimization, frame deduplication, color table minimization, and optional lossy compression. |
| **SVG** | SVGO, svgcleaner | Path simplification, redundant tag cleanup, XML minification. |

---

### 2. Output Destination & Filename Templating
Configure exactly where and how your files are saved via the new **Output & Formats** preferences:
* **Preserve Originals**: Keep the source file intact and write optimized files alongside it or into a designated folder.
* **Custom Output Folder**: Select any directory on your filesystem to collect all optimized assets.
* **Filename Tokens**: Prepend prefixes or suffixes using templating tags:
  * `{date}`: Current timestamp (`yyyyMMdd-HHmmss`).
  * `{date:FORMAT}`: Custom date formatting, e.g., `{date:yyyy-MM-dd}` or `{date:HHmm}`.
* **Live Preview**: See immediately how sample files like `photo.jpg` will be named before running jobs.

---

### 3. Queue Filtering & Real-Time Analytics
* **Status Filter Bar**: Instantly toggle between `All`, `Active`, `Done`, and `Failed` items with live badges.
* **Batch Controls**: Quick actions to **Retry Failed** items or **Clear Done** items without interrupting running tasks.
* **Multi-Selection Savings**: Select any subset of rows in the table to see targeted metrics:
  ```
  4 selected: 2.4 MB → 1.8 MB (saved 614 KB / 25.1%)
  ```

---

### 4. ⏱️ Tool Execution Timings & Live Benchmarks
* **Per-File Tool Breakdown Popover**: Every completed job tracks how much time each engine took and how many bytes it squeezed. Click the gauge icon or hover over any status icon to see:
  ```
  ⏱️ mark-test.png (Total: 3.92 s)
  • OxiPNG:   18 ms   (saved 31.4% / 15.2 KB)
  • AdvPNG:   85 ms   (no savings)
  • Zopfli:   3.82 s  (saved 0.5% / 280 B)
  ```
* **Persistent Engine Benchmarks in Preferences**: View historical and live statistics for every engine under *Preferences → Optimization speed*:
  * **Average Execution Time**: e.g., `21 ms`, `3.85 s`.
  * **Last Run Duration**: e.g., `18 ms`.
  * **Run Counts & Speed Ratings**: Dynamic badges (`⚡ Ultra-Fast`, `🚀 Fast`, `🐢 Exhaustive`).
  * **One-Click Reset**: Clear metrics anytime with *Reset Benchmark Stats*.

---

## ⚡ Performance & Engine Guide

ImageOptim utilizes a multi-engine cascade to ensure the absolute smallest file size. Understanding how the engines operate helps you configure optimal speed vs. compression trade-offs:

### Apple Silicon Scheduling (P-Cores vs E-Cores)
Apple Silicon chips (M1/M2/M3/M4 Pro/Max/Ultra) feature a hybrid architecture combining high-performance **P-cores** and energy-efficient **E-cores**. 
* In ImageOptim 2.0, the concurrency scheduler inspects `sysctl hw.perflevel0.logicalcpu` to limit worker concurrency strictly to `P-cores - 1`.
* Batch execution runs under `.userInitiated` Quality-of-Service (QoS), preventing the macOS kernel from deprioritizing worker subprocesses to low-frequency E-cores.

### Speed vs. Exhaustive Compression: Zopfli & OxiPNG
When compressing PNG files:
1. **OxiPNG (Ultra-fast, Rust)**: Runs multi-threaded filter trials and DEFLATE compression in milliseconds.
2. **pngquant (Lossy)**: When "Lossy min quality" is set (e.g. 80-90%), `pngquant` reduces 24-bit PNGs to indexed palettes with visual indistinguishability in a fraction of a second.
3. **Zopfli (Exhaustive, Google)**: Zopfli is a brute-force DEFLATE optimizer that runs 15+ iterations per file. It tests thousands of path possibilities to shave the last 0.5%–2% of file size.
   * *Tip*: If you need instant processing for thousands of PNGs, uncheck **Zopfli** or lower the optimization level in Preferences. Leave Zopfli enabled when preparing production assets where every single byte counts.

---

## 🛠️ Building from Source

### Prerequisites
* **macOS 14.0+** with **Xcode 15 or 16** (command line tools installed).
* **Rust**: Installed via `rustup` (required for building OxiPNG).
* **Node.js 18+**: Required for building the SVGO engine.

### Quick Build (Generate DMG in One Step)
Clone the repository recursively and run the automated packaging script:

```bash
git clone --recursive https://github.com/afanjul/ImageOptim.git
cd ImageOptim
./scripts/build-dmg.sh
```

The resulting `ImageOptim-2.1.0.dmg` will be placed in `build/Build/Products/Release/ImageOptim-2.1.0.dmg`.

### Manual Build via Xcode
1. Open `imageoptim/ImageOptim.xcodeproj` in Xcode.
2. Select the `ImageOptim` scheme and build (`Cmd + B`) or run (`Cmd + R`).
3. Or build unsigned via command line:
   ```bash
   xcodebuild -project imageoptim/ImageOptim.xcodeproj \
     -scheme ImageOptim \
     -configuration Release \
     CODE_SIGN_IDENTITY="-" \
     CODE_SIGNING_REQUIRED=NO \
     CODE_SIGNING_ALLOWED=NO \
     build
   ```

---

## 📝 Changelog

### 🚀 Version 2.1.0
* **Google Jpegli Integration**: Added native standalone `cjpegli` worker producing 100% standard JPEGs with up to 35% smaller bit density using Google's perceptual psychovisual quantization matrices and progressive scans.
* **Option A Settings Overhaul**: Completely redesigned Preferences with a unified 5-tab segmented control, zero vertical jump between panels, and polished macOS HIG layout.
* **Byte-Cruncher Animated Drop Zone**: Custom interactive drop zone with real-time drag hover animations and visual cues.
* **Explicit Save Mode Redesign**: Replaced ambiguous preservation toggle with clear segmented picker (`Overwrite original` vs `Save as copy`) preventing unwanted copy creation.
* **Unified English Localization**: All user interface strings unified to clean, idiomatic English.
* **Engine Benchmarks & Formats**: Added live per-engine benchmark timings, speed categorizations, and format badges.

### 🌟 Version 2.0.0

### 🏗️ Architecture & Core
* Replaced legacy Objective-C/AppKit code with **Swift 6** and **SwiftUI** using actor-based concurrency (`Backend` framework + `ImageOptim` UI).
* Removed obsolete dependencies (legacy Sparkle autoupdater, proprietary PNGOUT binary).
* Implemented strict Apple Silicon P-Core concurrency management via `sysctl hw.perflevel0.logicalcpu` and `.userInitiated` QoS.
* Added Apple Silicon GPU acceleration patches to Google Guetzli Butteraugli metric.

### 🖼️ File Formats & Optimization
* Added **WebP** lossless optimization worker using `cwebp` (integrated from community Luna fork).
* Added **AVIF** optimization worker supporting AV1 image containers via `avifoptim` / `avifenc`.
* Added **JPEG XL** optimization worker supporting `.jxl` via `jxloptim` / `cjxl`.
* Added **HEIC / HEIF to JPEG** automatic conversion worker using Apple ImageIO hardware acceleration.
* Enhanced magic byte identification in `ImageFile.swift` to sniff WebP (`RIFF...WEBP`), AVIF (`ftypavif`), JPEG XL (`FF 0A` and ISOBMFF `ftypjxl `), and HEIC (`ftypheic`/`ftypmif1`).
* Updated `Info.plist` document types and drag-and-drop UTTypes to support next-gen image extensions.

### 🎛️ Workflow & User Experience
* Added **Output & Formats** settings tab:
  * In-place overwrite or non-destructive original preservation.
  * Custom output directory picker with sandbox security-scoped bookmark support.
  * Filename prefix and suffix templating with `{date}` and `{date:format}` tokens.
* Added real-time segmented **Queue Filter Bar** (`All`, `Active`, `Done`, `Failed`) with live count badges.
* Added **Retry Failed** and **Clear Done** batch control buttons.
* Added multi-selection savings calculation displaying aggregated source vs. optimized file sizes and percentage saved.
* Added **Tool Execution Timings & Popover Inspector**: click the gauge icon on any finished row or hover over the status to see exact per-tool durations and savings breakdown.
* Added **Persistent Engine Benchmarks** in Preferences (*Optimization speed* tab) displaying historical averages, last run duration, run counts, and speed categories (`⚡ Ultra-Fast`, `🚀 Fast`, `🐢 Exhaustive`).
* Added **Format-Grouped Engines & Visual Badges**: compression engines in Preferences and execution diagnostics are now cleanly categorized by target formats (`PNG`, `JPEG`, `WebP`, `AVIF`, `JXL`, `GIF`, `SVG`) with color-coded format badges and detailed tooltips explaining their algorithms.
* Modernized macOS Settings window with tabs for General, Output & Formats, Quality, and Engines.
* Updated About dialog and credits view reflecting the 2.0 community super-fork.

---

## 👥 Credits & Acknowledgements

* **Original ImageOptim Creator**: [Kornel Lesiński](https://github.com/kornelski) ([imageoptim.com](https://imageoptim.com)).
* **Community Super-Fork Port & Maintenance**: [afanjul](https://github.com/afanjul).
* **Key Fork Contributors**:
  * [@wokenlex](https://github.com/wokenlex) — Swift 6 & SwiftUI architecture rewrite, Apple Silicon GPU Butteraugli patches.
  * [@SharkyRawr](https://github.com/SharkyRawr) — WebP integration and modernization.
  * [@a-j-n](https://github.com/a-j-n) — Queue state management & selection summary.
  * [@HoobenWang](https://github.com/HoobenWang) — Custom output destination & template design.
  * [@tietjinator](https://github.com/tietjinator) — Modern pipeline patterns.
* **Upstream Optimization Tools**:
  * [OxiPNG](https://github.com/shssoichiro/oxipng) by Josh Holmer
  * [Zopfli](https://github.com/google/zopfli) by Google
  * [MozJPEG](https://github.com/mozilla/mozjpeg) by Mozilla
  * [Gifsicle](https://github.com/kohler/gifsicle) by Eddie Kohler
  * [pngquant](https://pngquant.org/) by Kornel Lesiński
  * [cwebp / libwebp](https://chromium.googlesource.com/webm/libwebp) by Google
  * [libavif](https://github.com/AOMediaCodec/libavif) by AOMedia
  * [libjxl](https://github.com/libjxl/libjxl) by JPEG XL Project
  * [SVGO](https://github.com/svg/svgo) by Kir Belevich

---

## 📄 License

ImageOptim is released under the **GNU General Public License v2 (GPL-2.0)** or later. See the `LICENSE` file for details. Included third-party command-line utilities retain their respective open-source licenses (BSD, Apache 2.0, MIT, zlib).

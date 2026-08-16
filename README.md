# ImageOptim 

#### temporary Mac OS 26+ build made with Swift / SwiftUI, with autoupdate (Sparkle) and PNGOUT removed
#### Guetzli contains patches for GPU (Apple Silicon) support.


[ImageOptim](https://imageoptim.com) is a GUI for lossless image optimization tools: Zopfli, [OxiPNG](https://lib.rs/crates/oxipng), AdvPNG, PNGCrush, [JPEGOptim](https://github.com/tjko/jpegoptim), Jpegtran, [Guetzli](https://github.com/google/guetzli), [Gifsicle](https://kornel.ski/lossygif), [SVGO](https://github.com/svg/svgo), [svgcleaner](https://github.com/RazrFalcon/svgcleaner) and [MozJPEG](https://github.com/mozilla/mozjpeg).

## Building

Requires:

* Xcode 26 or later, and an Apple silicon Mac (the app is Swift 6 / SwiftUI and targets macOS 26).
* [Rust](https://rust-lang.org/) installed via not Homebrew.
* [Node.js](https://nodejs.org/) 16 or later, used to bundle SVGO.

```sh
git clone --recursive https://imageoptim.com ImageOptim
cd ImageOptim
```

To get started, open `imageoptim/ImageOptim.xcodeproj`. It will automatically download and build all subprojects when run in Xcode.

The project is set up for the signing identity used for the official releases. Pick your own team in Signing & Capabilities, or build unsigned from the command line:

```sh
cd imageoptim
xcodebuild -target ImageOptim -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
```

In case of build errors, these sometimes help:

```sh
git submodule update --init
```

```sh
cd gifsicle # or pngquant
make clean
make
```

# Upstream maturity audit

Snapshot from the GitHub API on November 18, 2026. Last push measures repository activity and can include automated syncs. A dated entry is the latest GitHub release. An undated entry is a tag returned when the repository had no latest published release. Some projects publish outside GitHub.

## Selection notes

- DevToys.Tools is the source for built-in tools distributed by [DevToys](https://github.com/DevToys-app/DevToys), which had 32,291 stars and 1,797 forks at review.
- JWTKit ships under the [Vapor Swift server ecosystem](https://github.com/vapor/vapor) and has current tagged releases. What’s Your Sign is maintained by [Objective-See](https://objective-see.org/products/whatsyoursign.html) and has a recent signed release. Use it as a signing diagnostics reference.
- Older but widely adopted projects can serve as algorithm references. For example, zxcvbn’s last GitHub release was in 2017, and the macOS dotfiles settings may reflect older platform behavior. Validate the specific logic against supported macOS versions before reuse.
- PDFium’s archived GitHub mirror was dropped from the map. The current PDF rendering candidate is MuPDF, with the license tradeoff documented in the feature row.

## GitHub candidates

| Repository | Stars | Forks | Last push | Release or tag |
| --- | ---: | ---: | --- | --- |
| [ArtifexSoftware/mupdf](https://github.com/ArtifexSoftware/mupdf) | 3,059 | 510 | 2026-11-17 | [ios-ice](https://github.com/ArtifexSoftware/mupdf/tree/ios-ice) |
| [ArtifexSoftware/pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) | 3,547 | 505 | 2026-05-01 | [v0.5.13](https://github.com/ArtifexSoftware/pdf2docx/releases/tag/v0.5.13) · 2026-05-01 |
| [ClearURLs/Addon](https://github.com/ClearURLs/Addon) | 5,139 | 154 | 2026-11-17 | [1.27.3](https://github.com/ClearURLs/Addon/releases/tag/1.27.3) · 2025-02-05 |
| [DevToys-app/DevToys.Tools](https://github.com/DevToys-app/DevToys.Tools) | 104 | 60 | 2026-03-02 | — |
| [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg) | 67,526 | 14,661 | 2026-11-18 | [v0.6.1](https://github.com/FFmpeg/FFmpeg/tree/v0.6.1) |
| [HandBrake/HandBrake](https://github.com/HandBrake/HandBrake) | 25,048 | 1,757 | 2026-11-18 | [1.11.2](https://github.com/HandBrake/HandBrake/releases/tag/1.11.2) · 2026-06-07 |
| [ImageMagick/ImageMagick](https://github.com/ImageMagick/ImageMagick) | 17,884 | 1,713 | 2026-11-18 | [7.1.2-36](https://github.com/ImageMagick/ImageMagick/releases/tag/7.1.2-36) · 2026-11-16 |
| [Kozea/WeasyPrint](https://github.com/Kozea/WeasyPrint) | 9,797 | 904 | 2026-11-13 | [v70.0](https://github.com/Kozea/WeasyPrint/releases/tag/v70.0) · 2026-09-08 |
| [LibreOffice/core](https://github.com/LibreOffice/core) | 4,661 | 1,024 | 2026-11-18 | [windows_build_successful_2011_11_08](https://github.com/LibreOffice/core/tree/windows_build_successful_2011_11_08) |
| [MediaArea/MediaInfoLib](https://github.com/MediaArea/MediaInfoLib) | 806 | 227 | 2026-11-18 | [v26.10](https://github.com/MediaArea/MediaInfoLib/releases/tag/v26.10) · 2026-10-06 |
| [MonitorControl/MonitorControl](https://github.com/MonitorControl/MonitorControl) | 34,767 | 1,045 | 2026-10-14 | [v4.4.0](https://github.com/MonitorControl/MonitorControl/releases/tag/v4.4.0) · 2026-09-15 |
| [ShareX/ShareX](https://github.com/ShareX/ShareX) | 41,138 | 4,089 | 2026-11-18 | [v22.4.0](https://github.com/ShareX/ShareX/releases/tag/v22.4.0) · 2026-11-08 |
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | 3,809 | 438 | 2026-11-18 | [1.8.2](https://github.com/apple/swift-argument-parser/releases/tag/1.8.2) · 2026-06-04 |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | 1,741 | 243 | 2026-11-06 | [5.1.1](https://github.com/apple/swift-crypto/releases/tag/5.1.1) · 2026-11-03 |
| [argosopentech/argos-translate](https://github.com/argosopentech/argos-translate) | 6,673 | 512 | 2026-11-17 | [v1.4.0](https://github.com/argosopentech/argos-translate/releases/tag/v1.4.0) · 2021-08-24 |
| [arsenetar/dupeguru](https://github.com/arsenetar/dupeguru) | 7,969 | 558 | 2026-11-12 | [4.3.1](https://github.com/arsenetar/dupeguru/releases/tag/4.3.1) · 2022-07-09 |
| [audacity/audacity](https://github.com/audacity/audacity) | 19,101 | 2,736 | 2026-11-18 | [Audacity-4.0.2](https://github.com/audacity/audacity/releases/tag/Audacity-4.0.2) · 2026-11-02 |
| [axboe/fio](https://github.com/axboe/fio) | 6,431 | 1,444 | 2026-11-17 | [fio-3.43](https://github.com/axboe/fio/releases/tag/fio-3.43) · 2026-09-23 |
| [ayoisaiah/f2](https://github.com/ayoisaiah/f2) | 2,461 | 68 | 2026-11-12 | [v2.2.2](https://github.com/ayoisaiah/f2/releases/tag/v2.2.2) · 2025-11-10 |
| [blakeembrey/change-case](https://github.com/blakeembrey/change-case) | 2,406 | 111 | 2025-06-17 | [title-case@4.3.2](https://github.com/blakeembrey/change-case/releases/tag/title-case@4.3.2) · 2024-09-15 |
| [danielgatis/rembg](https://github.com/danielgatis/rembg) | 25,566 | 2,504 | 2026-11-06 | [v2.0.87](https://github.com/danielgatis/rembg/releases/tag/v2.0.87) · 2026-11-06 |
| [dathere/qsv](https://github.com/dathere/qsv) | 3,828 | 118 | 2026-11-18 | [29.0.0](https://github.com/dathere/qsv/releases/tag/29.0.0) · 2026-11-15 |
| [dropbox/zxcvbn](https://github.com/dropbox/zxcvbn) | 16,093 | 1,004 | 2024-08-19 | [v4.4.2](https://github.com/dropbox/zxcvbn/releases/tag/v4.4.2) · 2017-02-07 |
| [dynobo/normcap](https://github.com/dynobo/normcap) | 2,777 | 127 | 2026-10-31 | [v0.6.0](https://github.com/dynobo/normcap/releases/tag/v0.6.0) · 2025-08-31 |
| [exelban/stats](https://github.com/exelban/stats) | 43,491 | 1,635 | 2026-11-18 | [v3.1.0](https://github.com/exelban/stats/releases/tag/v3.1.0) · 2026-11-15 |
| [exiftool/exiftool](https://github.com/exiftool/exiftool) | 5,272 | 505 | 2026-11-16 | [13.64](https://github.com/exiftool/exiftool/tree/13.64) |
| [flameshot-org/flameshot](https://github.com/flameshot-org/flameshot) | 31,584 | 2,120 | 2026-11-18 | [v15.0.0](https://github.com/flameshot-org/flameshot/releases/tag/v15.0.0) · 2026-11-07 |
| [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 55,292 | 6,322 | 2026-11-18 | [v1.9.5](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5) · 2026-10-06 |
| [google/uuid](https://github.com/google/uuid) | 6,159 | 446 | 2024-11-14 | [v1.6.0](https://github.com/google/uuid/releases/tag/v1.6.0) · 2024-01-23 |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | 8,751 | 1,117 | 2026-11-05 | [v7.12.0](https://github.com/groue/GRDB.swift/releases/tag/v7.12.0) · 2026-11-01 |
| [iAmCorey/birth](https://github.com/iAmCorey/birth) | 625 | 28 | 2026-08-29 | [v0.2.11](https://github.com/iAmCorey/birth/releases/tag/v0.2.11) · 2026-08-29 |
| [jgm/pandoc](https://github.com/jgm/pandoc) | 46,962 | 4,436 | 2026-11-15 | [3.14](https://github.com/jgm/pandoc/releases/tag/3.14) · 2026-11-12 |
| [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 16,024 | 1,885 | 2026-11-18 | [react-fa](https://github.com/k2-fsa/sherpa-onnx/releases/tag/react-fa) · 2026-11-16 |
| [libarchive/libarchive](https://github.com/libarchive/libarchive) | 3,676 | 1,082 | 2026-11-17 | [v3.8.11](https://github.com/libarchive/libarchive/releases/tag/v3.8.11) · 2026-10-30 |
| [mactools-app/MacTools](https://github.com/mactools-app/MacTools) | 1,433 | 83 | 2026-11-18 | [v2.2.0](https://github.com/mactools-app/MacTools/releases/tag/v2.2.0) · 2026-11-02 |
| [maplibre/maplibre-native](https://github.com/maplibre/maplibre-native) | 2,324 | 696 | 2026-11-18 | [android-v13.5.4](https://github.com/maplibre/maplibre-native/releases/tag/android-v13.5.4) · 2026-11-09 |
| [mathiasbynens/dotfiles](https://github.com/mathiasbynens/dotfiles) | 31,520 | 8,361 | 2024-08-05 | — |
| [microsoft/playwright](https://github.com/microsoft/playwright) | 100,503 | 6,921 | 2026-11-18 | [v1.65.1](https://github.com/microsoft/playwright/releases/tag/v1.65.1) · 2026-11-13 |
| [mifi/lossless-cut](https://github.com/mifi/lossless-cut) | 46,160 | 2,342 | 2026-11-14 | [v3.70.2](https://github.com/mifi/lossless-cut/releases/tag/v3.70.2) · 2026-10-28 |
| [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 875 | 470 | 2026-11-18 | [3.33.0](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.33.0) · 2026-11-17 |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | 1,583 | 272 | 2026-11-15 | [0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) · 2026-05-07 |
| [newmarcel/KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | 7,052 | 280 | 2026-08-15 | [1.6.8](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.6.8) · 2025-09-12 |
| [ngryman/reading-time](https://github.com/ngryman/reading-time) | 1,428 | 47 | 2025-04-22 | [v1.5.0](https://github.com/ngryman/reading-time/releases/tag/v1.5.0) · 2021-09-10 |
| [nielsmouthaan/ejectify-macos](https://github.com/nielsmouthaan/ejectify-macos) | 590 | 80 | 2026-11-02 | [2.1.0](https://github.com/nielsmouthaan/ejectify-macos/tree/2.1.0) |
| [objective-see/WhatsYourSign](https://github.com/objective-see/WhatsYourSign) | 372 | 29 | 2026-04-03 | [v3.2.2](https://github.com/objective-see/WhatsYourSign/releases/tag/v3.2.2) · 2026-04-03 |
| [obsproject/obs-studio](https://github.com/obsproject/obs-studio) | 79,693 | 11,285 | 2026-11-18 | [33.0.1](https://github.com/obsproject/obs-studio/releases/tag/33.0.1) · 2026-10-29 |
| [ocrmypdf/OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) | 35,344 | 2,459 | 2026-11-16 | [v17.14.2](https://github.com/ocrmypdf/OCRmyPDF/releases/tag/v17.14.2) · 2026-11-16 |
| [opencv/opencv](https://github.com/opencv/opencv) | 91,630 | 57,107 | 2026-11-18 | [5.1.0](https://github.com/opencv/opencv/releases/tag/5.1.0) · 2026-11-06 |
| [p0deje/Maccy](https://github.com/p0deje/Maccy) | 22,370 | 1,294 | 2026-10-26 | [2.8.0](https://github.com/p0deje/Maccy/releases/tag/2.8.0) · 2026-10-26 |
| [pdfcpu/pdfcpu](https://github.com/pdfcpu/pdfcpu) | 8,910 | 650 | 2026-11-02 | [v0.16.4](https://github.com/pdfcpu/pdfcpu/releases/tag/v0.16.4) · 2026-10-27 |
| [pilotmoon/Scroll-Reverser](https://github.com/pilotmoon/Scroll-Reverser) | 3,716 | 179 | 2026-11-04 | [v2.1.1](https://github.com/pilotmoon/Scroll-Reverser/releases/tag/v2.1.1) · 2026-11-04 |
| [py-pdf/pypdf](https://github.com/py-pdf/pypdf) | 10,304 | 1,708 | 2026-11-18 | [7.1.1](https://github.com/py-pdf/pypdf/releases/tag/7.1.1) · 2026-11-18 |
| [qpdf/qpdf](https://github.com/qpdf/qpdf) | 5,596 | 419 | 2026-09-26 | [v12.4.2](https://github.com/qpdf/qpdf/releases/tag/v12.4.2) · 2026-09-27 |
| [retextjs/retext](https://github.com/retextjs/retext) | 2,434 | 92 | 2025-02-04 | [9.0.0](https://github.com/retextjs/retext/releases/tag/9.0.0) · 2023-09-06 |
| [sindresorhus/Gifski](https://github.com/sindresorhus/Gifski) | 8,608 | 326 | 2026-09-11 | [v3.0.6](https://github.com/sindresorhus/Gifski/releases/tag/v3.0.6) · 2026-09-11 |
| [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 2,743 | 253 | 2026-09-11 | [3.1.0](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.1.0) · 2026-09-11 |
| [sindresorhus/LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) | 583 | 37 | 2024-01-11 | [v1.1.0](https://github.com/sindresorhus/LaunchAtLogin-Modern/releases/tag/v1.1.0) · 2023-12-21 |
| [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) | 9,941 | 1,156 | 2026-11-18 | [2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) · 2026-10-25 |
| [superhighfives/pika](https://github.com/superhighfives/pika) | 2,619 | 84 | 2026-11-18 | [2.0.3](https://github.com/superhighfives/pika/releases/tag/2.0.3) · 2026-11-17 |
| [tesseract-ocr/tesseract](https://github.com/tesseract-ocr/tesseract) | 77,581 | 10,921 | 2026-11-18 | [5.5.4](https://github.com/tesseract-ocr/tesseract/releases/tag/5.5.4) · 2026-10-28 |
| [turkaysoft/glow](https://github.com/turkaysoft/glow) | 552 | 35 | 2026-11-17 | [v26.15](https://github.com/turkaysoft/glow/releases/tag/v26.15) · 2026-11-17 |
| [tw93/Mole](https://github.com/tw93/Mole) | 75,496 | 2,718 | 2026-11-18 | [V1.73.0](https://github.com/tw93/Mole/releases/tag/V1.73.0) · 2026-11-18 |
| [unicode-org/icu](https://github.com/unicode-org/icu) | 3,647 | 953 | 2026-11-16 | [release-79.1](https://github.com/unicode-org/icu/releases/tag/release-79.1) · 2026-10-22 |
| [vapor/jwt-kit](https://github.com/vapor/jwt-kit) | 280 | 64 | 2026-11-18 | [5.9.1](https://github.com/vapor/jwt-kit/releases/tag/5.9.1) · 2026-11-18 |
| [xiph/rnnoise](https://github.com/xiph/rnnoise) | 5,972 | 1,090 | 2025-02-22 | [v0.2](https://github.com/xiph/rnnoise/releases/tag/v0.2) · 2024-04-15 |
| [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) | 208,869 | 18,427 | 2026-11-17 | [2026.10.26](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26) · 2026-10-26 |
| [zxing-cpp/zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) | 2,108 | 574 | 2026-11-18 | [v3.1.1](https://github.com/zxing-cpp/zxing-cpp/releases/tag/v3.1.1) · 2026-07-29 |

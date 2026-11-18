# Files and Mac utility repositories

**Direct** means the upstream project implements the core workflow. **Partial** means it implements a subset. **Building block** means it supplies a library, CLI, or example to integrate. This is a source review. Supported macOS versions, hardware, sandbox permissions, and integration behavior still need testing.

## Files (5)

| Feature | Candidate and license | Fit and reuse |
| --- | --- | --- |
| QR Code | [ZXing-C++](https://github.com/zxing-cpp/zxing-cpp) (Apache-2.0) | **Building block.** Generates QR images and decodes QR and common linear barcodes. Add native image import and text, URL, and Wi-Fi payload forms. |
| Batch Rename | [MacRename](https://github.com/simcrauk/MacRename) (MIT) | **Direct.** Swift renaming engine and app with replacement, counters, date and metadata tokens, case rules, preview, and undo. Adapt its engine to the suite's file-picker workflow. |
| Find Duplicates | [dupeGuru](https://github.com/arsenetar/dupeguru) (GPL-3.0) | **Direct.** Use its exact-content scan as the relevant workflow, with review and Trash handling. Its other modes can match similar files, which is a separate capability. |
| Zip & Unzip | [libarchive](https://github.com/libarchive/libarchive) ([BSD-style licenses by file](https://github.com/libarchive/libarchive/blob/master/COPYING)) | **Building block.** Read ZIP, RAR, 7z, and TAR and write ZIP with optional encryption. Add a Swift wrapper and verify archive creation and extraction against intended encryption and format variants. |
| Organize Downloads | [mac-downloads-sorter](https://github.com/Lucid06-K/mac-downloads-sorter) (Apache-2.0) | **Partial.** Uses macOS source metadata to route downloads based on their origin. Add an image-only preview, automatic hostname grouping, and an optional Photos album destination. Some downloads have no origin metadata. |

## Mac (18)

| Feature | Candidate and license | Fit and reuse |
| --- | --- | --- |
| Network Speed Test | [Hop](https://github.com/antonyshakirov/hop/blob/main/Sources/Hop/SpeedTest.swift) (MIT) | **Direct.** Native wrapper for Apple's built-in network benchmark, including download, upload, and responsiveness. The actual measurement runs against Apple's servers. |
| Clipboard History | [Maccy](https://github.com/p0deje/Maccy) (MIT) | **Direct.** Searchable clipboard history with copy and paste actions, ignored applications, and filtering of concealed clipboard data. Verify exclusions against supported password managers. |
| Storage Explorer | [DiskAnalyzer](https://github.com/brunokktro/DiskAnalyzer) (MIT) | **Direct.** SwiftUI disk usage scanning, treemap and Trash workflow. Add curated cleanup categories if needed. |
| Wi-Fi Password & QR | [macwifi](https://github.com/jaisonerick/macwifi) (MIT), [ZXing-C++](https://github.com/zxing-cpp/zxing-cpp) (Apache-2.0) | **Building blocks.** Combine user-authorized access to the selected saved network with QR generation. The Wi-Fi helper retains the macOS authorization prompt. |
| Disk Speed Test | [SSD Scope for Mac](https://github.com/ChakkritGit/SSD-Scope-for-Mac) (MIT) | **Direct.** Its benchmark provides a reference for timed disk reads and writes. The upstream app targets Apple Silicon. Verify the benchmark on removable drives and Intel Macs if both are supported. |
| Battery Health | [Stats](https://github.com/exelban/stats/tree/master/Modules) (MIT) | **Direct.** Battery and Bluetooth modules supply complementary data for built-in battery health, charge status, and accessory levels. Validate device coverage and power figures on the supported hardware. |
| Keep Awake | [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) (MIT) | **Direct.** Native menu bar utility with indefinitely active and timed wake prevention. Adapt the idle-inhibition and timer logic. |
| Uninstall App | [Hop](https://github.com/antonyshakirov/hop/blob/main/Sources/HopCore/AppUninstall.swift) (MIT) | **Direct.** Candidate for finding application-associated files and presenting them for removal. Verify file ownership and exclusion rules for shared data. |
| Presentation Mode | [Show Mode](https://github.com/stoatworks-labs/showmode) (MIT), [dotfiles macOS settings](https://github.com/mathiasbynens/dotfiles/blob/main/.macos) (MIT) | **Partial.** Show Mode provides sleep guards and reversible state changes. The settings script covers Finder desktop and Dock preferences. Compose them into one session with state restoration. |
| Clean Keyboard | [Hop](https://github.com/antonyshakirov/hop/blob/main/Sources/Hop/KeyboardLockController.swift) (MIT) | **Partial.** Implements temporary keyboard lock and an unlock gesture. Add the optional black-screen overlay and verify recovery on multi-display Macs. |
| Dead Pixel Test | [Glow](https://github.com/turkaysoft/glow) (MIT) | **Building block.** Upstream includes a Windows dead-pixel test. Adapt the solid-color test interaction to native full-screen windows on each macOS display. |
| Eject All Disks | [Ejectify](https://github.com/nielsmouthaan/ejectify-macos) ([MIT](https://github.com/nielsmouthaan/ejectify-macos/blob/main/LICENSE)) | **Direct.** Reuse its selected-volume discovery and Disk Arbitration eject behavior. Add a user-triggered batch action and verify external disks, cards, disk images, and busy-volume reporting. |
| Login & Background Items | [Birth](https://github.com/iAmCorey/birth) (MIT) | **Direct.** Native SwiftUI utility for listing background tasks, login items and launch services, showing signing identity, and disabling selected entries. Verify against the target macOS versions. |
| Fix “App Is Damaged” | [What's Your Sign](https://github.com/objective-see/WhatsYourSign) (GPL-3.0) | **Partial.** Read-only publisher and signing diagnostics for a selected application. Quarantine management is outside this mapping. |
| Reset Permissions | [AppReset](https://github.com/Shahfarzane/AppReset) (MIT) | **Direct.** Native app picker and wrapper for the macOS privacy reset command. Reuse the per-app, per-service reset behavior. |
| Hidden Settings | [dotfiles macOS settings](https://github.com/mathiasbynens/dotfiles/blob/main/.macos) (MIT) | **Building block.** Reference for Finder, Dock, and related preferences. Identify which settings still work on supported releases, and make each one reversible. |
| Display Control | [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT) | **Direct.** Native DDC/CI brightness, contrast, and volume control with alternative software dimming where applicable. Confirm supported displays, ports, and docks. |
| Mouse Fixes | [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) (Apache-2.0), [smoothscrolld](https://github.com/oochernyshev/homebrew-smoothscroll) (MIT) | **Building blocks.** Reuse independent scroll direction and wheel step-size logic from Scroll Reverser and velocity-based smoothing from smoothscrolld. Integrate both into one event pipeline. |

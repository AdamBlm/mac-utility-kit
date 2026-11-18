# Files and Mac utility repositories

**Direct** means the upstream project implements the core workflow. **Partial** means it implements a subset. **Building block** means it supplies a library, CLI, or example to integrate. This is a source review. Supported macOS versions, hardware, sandbox permissions, and integration behavior still need testing.

## Files (5)

| Feature | Candidate and license | Fit and reuse |
| --- | --- | --- |
| QR Code | [ZXing-C++](https://github.com/zxing-cpp/zxing-cpp) (Apache-2.0) | **Building block.** Generates QR images and decodes QR and common linear barcodes. Add native image import and text, URL, and Wi-Fi payload forms. |
| Batch Rename | [F2](https://github.com/ayoisaiah/f2) (MIT) | **Direct CLI.** Wrap dry runs, replacement, counters, metadata variables, and undo in a native review UI. Validate date and capitalization rules. |
| Find Duplicates | [dupeGuru](https://github.com/arsenetar/dupeguru) (GPL-3.0) | **Direct.** Use its exact-content scan as the relevant workflow, with review and Trash handling. Its other modes can match similar files, which is a separate capability. |
| Zip & Unzip | [libarchive](https://github.com/libarchive/libarchive) ([BSD-style licenses by file](https://github.com/libarchive/libarchive/blob/master/COPYING)) | **Building block.** Read ZIP, RAR, 7z, and TAR and write ZIP with optional encryption. Add a Swift wrapper and verify archive creation and extraction against intended encryption and format variants. |
| Organize Downloads | No mature upstream match identified | **Native implementation.** Read Finder origin metadata where available. Group images in a preview and apply selected folder or Photos destinations. |

## Mac (18)

| Feature | Candidate and license | Fit and reuse |
| --- | --- | --- |
| Network Speed Test | No mature upstream match identified | **Native implementation.** Use the macOS networkQuality command for download, upload, and responsiveness. Build progress and reporting. |
| Clipboard History | [Maccy](https://github.com/p0deje/Maccy) (MIT) | **Direct.** Searchable clipboard history with copy and paste actions, ignored applications, and filtering of concealed clipboard data. Verify exclusions against supported password managers. |
| Storage Explorer | [Mole CLI](https://github.com/tw93/Mole) (GPL-3.0) | **Direct CLI reference.** Mole documents disk analysis and cleanup. Build a native visualization and file review before removal. |
| Wi-Fi Password & QR | [ZXing-C++](https://github.com/zxing-cpp/zxing-cpp) (Apache-2.0) | **Partial.** Keep ZXing-C++ for QR handling. Use user-authorized macOS password retrieval and preserve OS prompts. |
| Disk Speed Test | [fio](https://github.com/axboe/fio) (GPL-2.0) | **Direct benchmark engine.** Configure timed reads and writes in user-selected scratch storage. Build results reporting and cleanup. |
| Battery Health | [Stats](https://github.com/exelban/stats/tree/master/Modules) (MIT) | **Direct.** Battery and Bluetooth modules supply complementary data for built-in battery health, charge status, and accessory levels. Validate device coverage and power figures on the supported hardware. |
| Keep Awake | [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) (MIT) | **Direct.** Native menu bar utility with indefinitely active and timed wake prevention. Adapt the idle-inhibition and timer logic. |
| Uninstall App | [Mole CLI](https://github.com/tw93/Mole) (GPL-3.0) | **Direct CLI reference.** Review Mole’s associated-file discovery and cleanup logic. Build native preview, selection, and removal UI. |
| Presentation Mode | [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) (MIT) | **Partial.** Use the sleep-inhibition workflow and implement reversible desktop and Dock visibility changes natively. |
| Clean Keyboard | No mature upstream match identified | **Native implementation.** Build a temporary input pause and optional display overlay with an independent escape path and timeout. |
| Dead Pixel Test | [Glow](https://github.com/turkaysoft/glow) (MIT) | **Building block.** Upstream includes a Windows dead-pixel test. Adapt the solid-color test interaction to native full-screen windows on each macOS display. |
| Eject All Disks | [Ejectify](https://github.com/nielsmouthaan/ejectify-macos) ([MIT](https://github.com/nielsmouthaan/ejectify-macos/blob/main/LICENSE)) | **Direct.** Reuse its selected-volume discovery and Disk Arbitration eject behavior. Add a user-triggered batch action and verify external disks, cards, disk images, and busy-volume reporting. |
| Login & Background Items | [Birth](https://github.com/iAmCorey/birth) (MIT) | **Direct.** Native SwiftUI utility for listing background tasks, login items and launch services, showing signing identity, and disabling selected entries. Verify against the target macOS versions. |
| Fix “App Is Damaged” | [What's Your Sign](https://github.com/objective-see/WhatsYourSign) (GPL-3.0) | **Partial.** Read-only publisher and signing diagnostics for a selected application. Quarantine management is outside this mapping. |
| Reset Permissions | No mature upstream match identified | **Native implementation.** Use supported macOS per-app privacy resets, with a user-selected app and service. |
| Hidden Settings | [dotfiles macOS settings](https://github.com/mathiasbynens/dotfiles/blob/main/.macos) (MIT) | **Building block.** Reference for Finder, Dock, and related preferences. Identify which settings still work on supported releases, and make each one reversible. |
| Display Control | [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT) | **Direct.** Native DDC/CI brightness, contrast, and volume control with alternative software dimming where applicable. Confirm supported displays, ports, and docks. |
| Mouse Fixes | [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) (Apache-2.0) | **Partial.** Supports independent direction and wheel stepping. Build or separately validate smooth scrolling. |

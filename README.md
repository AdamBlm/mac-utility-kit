<p align="center">
  <img src="assets/branding/mac-utility-kit.svg" alt="" width="80" height="80">
</p>

<h1 align="center">Mac Utility Kit</h1>

<p align="center">105 native macOS tools for PDFs, media, files, and everyday work.</p>

<p align="center">
  <strong><a href="https://github.com/AdamBlm/mac-utility-kit/releases/download/v0.0.1-preview.4/Mac.Utility.Kit.Preview.4.dmg">Download for Mac</a></strong>
  · <a href="https://github.com/AdamBlm/mac-utility-kit/releases">Release notes</a>
  · <a href="docs/tool-guide.md">Tool guide</a>
</p>

<p align="center"><sub>Apple silicon · macOS 15 or later · Free and open source</sub></p>

![Browse Tools in the tinted Mac Utility Kit workspace](docs/images/browse-tools.png)

## Explore the tools

| Category | What you can do |
| --- | --- |
| [Images](docs/feature-inventory.md#images-13) | Resize and compress in batches, remove backgrounds, blur faces, or annotate screenshots. |
| [Documents](docs/feature-inventory.md#docs-23) | Compress PDFs, choose pages for a merge, sign forms, or make scans searchable. |
| [Video](docs/feature-inventory.md#video-16) | Compress, trim, merge, and convert clips, create GIFs, or record your screen. |
| [Audio](docs/feature-inventory.md#audio-6) | Record, trim, convert, or clean up audio. |
| [Text and speech](docs/feature-inventory.md#text--speech-10) | Extract text from images, transcribe recordings, translate, or read documents aloud. |
| [Files](docs/feature-inventory.md#files-5) | Rename in batches, find duplicates, organize downloads, or open archives. |
| [Mac](docs/feature-inventory.md#mac-18) | Check battery health, see what fills your disk, manage displays, or keep your Mac awake. |
| [Developer](docs/feature-inventory.md#developer-14) | Format JSON, compare text, convert CSV, test regex, or verify checksums. |

Press **⌘K** to find a tool by name. Star tools you use often to keep them in **Favorites**. Find recently opened tools under **Recents**.

## Install on your Mac

[Download the DMG](https://github.com/AdamBlm/mac-utility-kit/releases/download/v0.0.1-preview.4/Mac.Utility.Kit.Preview.4.dmg), open it, and drag Mac Utility Kit into **Applications**.

### Opening a preview download for the first time

Preview downloads use an ad hoc signature. macOS may block the first launch because the preview has no Apple Developer ID signature or notarization.

1. If you downloaded the preview from this project's GitHub Releases page and trust the source, drag **Mac Utility Kit.app** into **Applications** and try opening it.
2. If macOS blocks it, open **System Settings → Privacy & Security**, then select **Open Anyway**.
3. Confirm when prompted. macOS saves the exception for this copy of the app. Managed Macs may restrict this option. [Apple's first-launch guidance](https://support.apple.com/en-us/102445)

I’m keeping the preview simple while I see how much interest there is. If enough people find the app useful, I’d like to cover the cost of Apple Developer Program membership so I can offer signed and notarized downloads.

## Open files from Finder

Right-click a PDF or image in Finder to open it directly in a Mac Utility Kit tool. Finder may group these actions under **Services**.

| Finder selection | Direct action |
| --- | --- |
| One or more PDFs | **Compress PDF with Mac Utility Kit** |
| Two or more PDFs | **Combine PDFs with Mac Utility Kit** |
| One or more images | **Compress Images with Mac Utility Kit** |

For your own shortcuts, star tools in the app, then choose **Favorite Actions in Mac Utility Kit** from Finder. The picker shows starred tools that can open every selected file. For example, star **Resize Images** to make it available when you select images.

The chosen tool opens with the files loaded. You can review the settings before starting an export.

If the actions are missing, install a build that includes Finder actions in **Applications**, then check **System Settings → Keyboard → Keyboard Shortcuts → Services**.

## Optional engines

Many tools work with the frameworks that ship with macOS. If a feature needs an additional engine, open **Settings → Engines** or follow the setup instructions in that tool. Setup panels can provide a Homebrew command or let you select an installed executable.

| For | You may need |
| --- | --- |
| Downloading video from supported sites | yt-dlp, plus FFmpeg for stream merging or conversion |
| WebM export, animated GIFs, or burning in subtitles | FFmpeg with the encoders or filters required by the tool |
| Compressing PDFs | qpdf or Ghostscript, depending on the document and compression settings |
| Encrypting or decrypting PDFs | qpdf |
| Office document conversion | LibreOffice |
| Transcription | whisper.cpp and a downloaded model |

If managed Video Tools are unavailable in your build, use **Copy Setup Command** in the video setup panel, run the command in Terminal, then choose **Detect Installed Tools** where offered. Managed setup and its optional automatic updates are available in builds configured with a signed engine feed.

## Privacy and network use

File workflows such as image editing, PDF compression, OCR, and transcription run locally once their engines and models are installed. Download Video, Web Page to PDF, Network Speed Test, and map lookups can use the network. App and engine updates, model downloads, and macOS language-pack setup can also connect. Clipboard History is opt-in. Screen and microphone tools ask for their applicable macOS permissions.

The optional `muk` CLI and local MCP server expose a subset of tools. See [Terminal and local MCP](docs/tool-guide.md#terminal-and-local-mcp) for commands and setup.

## Build or contribute

You’ll need an Apple silicon Mac with macOS 15 or later and Xcode 26 or later.

```sh
./scripts/build-app.sh
open "build/Mac Utility Kit.app"
```

Report a bug or suggest an improvement in [GitHub Issues](https://github.com/AdamBlm/mac-utility-kit/issues). For pull requests, testing, and packaging, see the [contributing guide](CONTRIBUTING.md).

[Development plan](docs/plan/README.md) · [Open-source components](docs/reuse/README.md) · [Third-party notices](licenses/)

## License

Mac Utility Kit's original code and documentation are available under the [MIT License](LICENSE). Third-party components and assets retain their own licenses. See [third-party notices](licenses/) and the [engine release plan](docs/plan/engine-release.md) for bundled and optional tools.

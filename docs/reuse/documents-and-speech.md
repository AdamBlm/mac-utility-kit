# Open-source reuse for Docs and Text & Speech

The map covers 23 document tools and 9 text and speech tools. **Direct** covers the core operation. **Partial** covers a working implementation with a named parity gap. **Building block** identifies a component that needs application-specific logic. The mapping is based on repository source, upstream documentation, and license notices. Integration and output quality were assessed from those sources.

## Docs (23)

| Feature | Repository and license | Fit and integration |
| --- | --- | --- |
| Scan Document | [OpenCV](https://github.com/opencv/opencv) (Apache-2.0) | **Building block.** Use OpenCV for page contours, perspective correction, and cleanup. Build Continuity Camera capture and PDF assembly. |
| Redact PDF | [MuPDF](https://github.com/ArtifexSoftware/mupdf) (AGPL-3.0 or commercial) | **Direct engine.** Apply permanent redactions with MuPDF and verify removed text and embedded image data. Build the selection UI. |
| Fill & Flatten Forms | [pypdf](https://github.com/py-pdf/pypdf) (BSD-3-Clause), [OpenCV](https://github.com/opencv/opencv) (Apache-2.0) | **Partial.** pypdf can fill and flatten existing fields. OpenCV supplies image-processing primitives. Build and validate scanned-form detection and field placement in-house. |
| Make PDF Searchable | [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) (MPL-2.0) | **Direct.** Use the local CLI to add an OCR text layer to scans. Confirm the chosen OCR/rasterization dependencies for the macOS package. |
| PDF to Word | [pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) (MIT, depends on AGPL-3.0 or commercially licensed PyMuPDF) | **Partial.** Produces editable DOCX and reconstructs page layout from text-based PDFs. Validate native heading/list semantics and add OCR for image-only PDFs. |
| Sign PDF | [pypdf](https://github.com/py-pdf/pypdf) (BSD-3-Clause) | **Building block.** Merge a generated visible signature overlay into the page. Build the signature capture and placement UI. |
| Merge PDFs | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct for PDFs.** Merge page selections and build image-to-PDF conversion before merging mixed inputs. |
| Split PDF | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct.** Split individual pages or produce one file per chosen range. |
| Organize PDF | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct engine.** Reorder, rotate, and remove pages. Build thumbnail views and interactive ordering. |
| Delete Pages | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct.** Write a new file from the complement of the selected page ranges. Validate bookmarks and forms in edited copies. |
| Extract Pages | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct.** Provide selected page ranges to qpdf's page-selection CLI or library. |
| Images to PDF | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Render ordered images into PDF. Check the ImageMagick PDF security policy and preserve intended orientation and sizing. |
| Crop PDF | [pypdf](https://github.com/py-pdf/pypdf) (BSD-3-Clause) | **Direct.** Set page crop boxes from selection coordinates. Cropping changes visible bounds and can leave out-of-bounds content in the file. |
| Compress PDF | [pypdf](https://github.com/py-pdf/pypdf) (BSD-3-Clause) | **Partial.** Recompress embedded images and compress page content streams while preserving selectable text. Validate forms, links, and file-size outcomes. |
| Add Password | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct.** Encrypt with user and owner passwords and set print/extraction restrictions. PDF viewers enforce the restrictions. |
| Remove Password | [qpdf](https://github.com/qpdf/qpdf) (Apache-2.0) | **Direct.** Decrypt to a new file after supplying the document password. |
| PDF to Images | [MuPDF](https://github.com/ArtifexSoftware/mupdf) (AGPL-3.0 or commercial) | **Building block.** Render pages and encode results in the selected format. HEIC needs a separate encoder. |
| Convert Documents | [Pandoc](https://github.com/jgm/pandoc) (GPL-2.0-or-later), [LibreOffice](https://github.com/LibreOffice/core) ([MPL-2.0 with third-party licenses](https://www.libreoffice.org/licenses/)) | **Direct with routing.** Pandoc handles Markdown, HTML, DOCX, ODT and text workflows. Route unsupported combinations, including RTF input, through LibreOffice. Publish the supported input/output matrix and test round trips. |
| Word to PDF | [LibreOffice](https://github.com/LibreOffice/core) ([MPL-2.0 with third-party licenses](https://www.libreoffice.org/licenses/)) | **Direct.** Invoke Writer's headless PDF export for DOC/DOCX, RTF and text. |
| PowerPoint to PDF | [LibreOffice](https://github.com/LibreOffice/core) ([MPL-2.0 with third-party licenses](https://www.libreoffice.org/licenses/)) | **Direct.** Invoke Impress's headless PDF export and validate fonts and slide masters. |
| Excel to PDF | [LibreOffice](https://github.com/LibreOffice/core) ([MPL-2.0 with third-party licenses](https://www.libreoffice.org/licenses/)) | **Direct.** Invoke Calc's headless PDF export and respect sheet print areas and scaling. |
| Web Page to PDF | [Playwright](https://github.com/microsoft/playwright) (Apache-2.0, browser components have separate notices) | **Partial.** Chromium's [page.pdf API](https://playwright.dev/docs/api/class-page#page-pdf) provides paginated printing. Continuous-page export needs sizing and testing against very long pages. |
| Markdown to PDF | [Pandoc](https://github.com/jgm/pandoc) (GPL-2.0-or-later), [WeasyPrint](https://github.com/Kozea/WeasyPrint) (BSD-3-Clause) | **Direct.** Convert Markdown using Pandoc, either through a supported PDF engine or via HTML rendered by WeasyPrint. |

## Text & Speech (10)

| Feature | Repository and license | Fit and integration |
| --- | --- | --- |
| Transcribe | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) | **Direct with media decoding.** Use the local Whisper engine and its timestamped output. Decode video soundtracks and audio formats to supported audio using the media pipeline. |
| Summarize | [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) (MIT) | **Building block.** Swift-native local language-model inference on Apple silicon. Add text extraction, summary prompts, and long-document chunking. |
| Extract Text | [Tesseract](https://github.com/tesseract-ocr/tesseract) (Apache-2.0), [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) (MPL-2.0) | **Building blocks.** Use Tesseract for images and OCRmyPDF for scans. Build PDF page selection, local model discovery, and copy/export. |
| Capture Text | [NormCap](https://github.com/dynobo/normcap) (GPL-3.0-or-later) | **Direct reference.** NormCap provides region capture, local OCR, and clipboard output. Use native capture if a Swift UI is preferred. |
| Translate | [Argos Translate](https://github.com/argosopentech/argos-translate) (MIT) | **Building block.** Use offline translation and implement format-preserving text extraction and reinsertion for Office and subtitle files. |
| Text to Speech | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) | **Building block.** Use a local TTS pipeline to synthesize audio. Add document extraction, playback, voices, and export. Check voice model licenses. |
| Ask a Document | [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) (MIT), [MuPDF](https://github.com/ArtifexSoftware/mupdf) (AGPL-3.0 or commercial) | **Building blocks.** Extract text per page and use local inference. Build retrieval, citation checking, and the page-linked answer interface. |
| Word Counter | [retext](https://github.com/retextjs/retext) (MIT), [reading-time](https://github.com/ngryman/reading-time) (MIT) | **Building block.** Use or adapt text tokenization and reading-speed estimates. Compute word frequencies and Unicode-aware character, sentence, and paragraph counts in the application. |
| Batch Find & Replace | [ICU](https://unicode-org.github.io/icu/userguide/strings/regexp.html) and [VS Code search](https://code.visualstudio.com/docs/editing/codebasics#_search-and-replace) | Reuse the app’s bounded ICU evaluator for regex and Foundation for literal matching. Preview changes for each file and export verified copies without overwriting the sources. |
| Case Converter | [change-case](https://github.com/blakeembrey/change-case) (MIT) | **Direct for identifier styles.** Reuse its case rules or port them to Swift with attribution. Use locale-aware upper/lower transformations and define title-case rules for prose. |

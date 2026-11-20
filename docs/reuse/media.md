# Video, audio, and image reuse map

The 33 rows follow the [feature inventory](../feature-inventory.md). **Direct** means a source app implements the core workflow. **Building block** means a library or command can perform the operation and needs app integration. **Partial** means a capability still needs separate engineering. License notes refer to the upstream sources, and the mappings were reviewed from code and documentation without runtime tests.

## Video (16)

| Feature | Open-source repository and license | Reuse and remaining work |
| --- | --- | --- |
| Download Video | [yt-dlp](https://github.com/yt-dlp/yt-dlp#license) (Unlicense source, release binaries vary) | **Building block.** Wrap the CLI's metadata and format selection for available audio languages, progress, and audio-only output. Install or detect FFmpeg for post-processing. |
| Burn In Subtitles | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent), [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) | **Building blocks.** Generate timed subtitles locally when the user provides none, then render supplied or generated SRT via FFmpeg's [subtitles filter](https://ffmpeg.org/ffmpeg-filters.html#subtitles-1). Confirm libass is enabled. |
| Extract Subtitles | [FFprobe and FFmpeg](https://ffmpeg.org/documentation.html) (LGPL/GPL, build-dependent) | Inspect and explicitly map a single text subtitle stream to SRT or WebVTT. |
| Change Speed | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Use setpts and atempo for timing and pitch-preserving audio. Build synchronized preview and track handling. |
| Extract Frames | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent), [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building blocks.** Decode selected frames with FFmpeg. ImageMagick can supply HEIC export with the appropriate delegate. Build frame selection and thumbnails. |
| Record Screen | [OBS Studio](https://github.com/obsproject/obs-studio) (GPL-2.0-or-later) | **Native reference.** OBS has macOS ScreenCaptureKit and audio capture. Build the region picker and click indicators separately. |
| Compress Video | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent), [HandBrake](https://github.com/HandBrake/HandBrake) (GPL-2.0) | **Engine and reference.** Use FFmpeg for encoding and HandBrake as a macOS compression workflow reference. Validate quality, acceleration, and output reporting. |
| Convert Video | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Transcode to MP4, MOV, WebM, and M4V where supported by the selected build. |
| Resize Video | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Use the [scale filter](https://ffmpeg.org/ffmpeg-filters.html#scale) with explicit dimensions, aspect policy, and encoder-compatible sizes. |
| Crop & Rotate Video | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Use crop, transpose, and flip filters. Handle orientation metadata and add interactive preview. |
| Media Info | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent), [MediaInfoLib](https://github.com/MediaArea/MediaInfoLib) (BSD-2-Clause) | **Building blocks.** Read JSON from [ffprobe](https://ffmpeg.org/ffprobe.html) or integrate MediaInfoLib. Present container, stream, timing, codec, and tag data. |
| Trim Video | [LosslessCut](https://github.com/mifi/lossless-cut) (GPL-2.0), [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Direct reference.** Use LosslessCut to study the keyframe-aware UX and drive FFmpeg stream copy. Lossless cuts can be limited by keyframe placement. |
| Merge Videos | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Concatenate compatible streams and normalize incompatible inputs before joining. Add clip ordering. |
| Mute Video | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Select streams and copy the video while excluding audio. Test metadata and caption retention. |
| Replace Audio | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Stream-map a replacement or mix it through the [amix filter](https://ffmpeg.org/ffmpeg-filters.html#amix). Set durations, looping, gains, and track selection in the app. |
| Video to GIF | [Gifski for macOS](https://github.com/sindresorhus/Gifski) (MIT application wrapper) | **Direct reference.** Adapt clip selection, frame rate, sizing, and progress. Verify licenses for the actual encoder and other dependencies before redistribution. |

## Audio (6)

| Feature | Open-source repository and license | Reuse and remaining work |
| --- | --- | --- |
| Clean Up Audio | [RNNoise](https://github.com/xiph/rnnoise) (BSD-3-Clause), [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building blocks.** Use RNNoise for speech noise suppression and FFmpeg's [audio filtering](https://ffmpeg.org/ffmpeg-filters.html#Audio-Filters) for hum removal, track extraction, and remuxing. Tune filters separately for speech and music. |
| Record Audio | [Audacity](https://github.com/audacity/audacity) (GPL-3.0) | **Direct reference.** Study cross-platform microphone recording and level monitoring. Add macOS-native capture UI and use whisper.cpp from the transcription row for optional transcription. |
| Trim Audio | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent), [Audacity](https://github.com/audacity/audacity) (GPL-3.0) | **Engine and reference.** Use FFmpeg for trimming and Audacity as an editor reference. Expose the precision tradeoff between stream copy and re-encoding. |
| Merge Audio | [FFmpeg audio filters](https://ffmpeg.org/ffmpeg-filters.html#Audio-Filters) (LGPL/GPL, build-dependent) | Reuse concat, apad, and acrossfade to join clips with verified timing and normalized sample and channel formats. |
| Extract Audio | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Map the chosen audio stream to an independent file and copy or transcode for the requested container. |
| Convert Audio | [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building block.** Verify MP3, M4A, WAV, FLAC, and AIFF encoders in the selected build. |

## Images (13)

| Feature | Open-source repository and license | Reuse and remaining work |
| --- | --- | --- |
| Screenshot | [MacTools](https://github.com/mactools-app/MacTools) (GPL-3.0), [ShareX](https://github.com/ShareX/ShareX) (GPL-3.0) | **Direct reference.** MacTools documents native region and scrolling capture. ShareX is an established Windows reference for scrolling capture. Validate window isolation and Retina output on macOS. |
| Blur Faces | [OpenCV](https://github.com/opencv/opencv) (Apache-2.0) | **Building block.** Use a supported detector and blur, pixelation, or solid masks. Add user review for missed faces. |
| Beautify Screenshot | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Compose backgrounds, rounded corners, padding, and shadows. Build original presets, editor, and preview. |
| Remove Background | [rembg](https://github.com/danielgatis/rembg) (MIT code) | **Building block.** Use the local segmentation engine and add preview, batch export, and background options. Verify the chosen model license separately. |
| Convert Images | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Use ImageIO for native formats and the existing ImageMagick adapter for WebP. The converter exposes lossy quality and lossless encoding separately, following [ImageMagick’s WebP options](https://imagemagick.org/webp/). The ImageMagick integration fixture checks alpha preservation and staging cleanup. |
| Compress Images | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Select format-specific quality and optimize output. Verify preservation of profiles and report the size difference. |
| Resize Images | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Scale by percentage, longest edge, or exact size. Build batch controls. |
| Rotate Images | [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Building block.** Use rotate, flip, and flop operations and normalize orientation metadata. |
| Remove Metadata | [ExifTool](https://github.com/exiftool/exiftool) (Perl terms) | **Building block.** Remove selected EXIF, GPS, IPTC, and XMP fields. Verify per-format retention, especially orientation and color profiles. Check license terms for the distribution route. |
| Color Picker | [Pika](https://github.com/superhighfives/pika) (MIT) | **Direct reference.** Native screen sampler with HEX, RGB, HSL, and other formats. Adapt sampling, conversion, and clipboard copy. |
| Redact Image | [Flameshot](https://github.com/flameshot-org/flameshot) (GPL-3.0), [ImageMagick](https://github.com/ImageMagick/ImageMagick) (ImageMagick License) | **Editor reference and building block.** Use Flameshot for drawing interaction and ImageMagick for pixelation, blur, and opaque compositing. Flatten output for permanent masking. |
| Annotate Screenshot | [Flameshot](https://github.com/flameshot-org/flameshot) (GPL-3.0), [ShareX](https://github.com/ShareX/ShareX) (GPL-3.0) | **Direct references.** Mature screenshot editors provide arrows, text, and shapes. ShareX also supplies a numbered-step reference. Adapt to an original native editor. |
| Watermark | [ImageMagick](https://github.com/ImageMagick/ImageMagick) ([ImageMagick License](https://imagemagick.org/license/)), [pdfcpu](https://github.com/pdfcpu/pdfcpu) (Apache-2.0), [FFmpeg](https://github.com/FFmpeg/FFmpeg) (LGPL/GPL, build-dependent) | **Building blocks.** Composite or draw on images, use pdfcpu [foreground stamps](https://pdfcpu.io/core/stamp/) for PDFs, and FFmpeg's [overlay and drawtext](https://ffmpeg.org/ffmpeg-filters.html) for video. Share position, opacity, and batch settings across formats. |

[FFmpeg's license guidance](https://ffmpeg.org/legal.html) documents LGPL-2.1-or-later as the baseline and GPL terms for builds with optional GPL components. Check the exact FFmpeg build, enabled codecs and dependencies, and the applicable license files before bundling it.

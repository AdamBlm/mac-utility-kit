# Contributing to Mac Utility Kit

## Build and test

Use an Apple silicon Mac with macOS 15 or later and Xcode 26 or later. From the repository root:

```sh
swift build
swift test
./scripts/build-app.sh
open "build/Mac Utility Kit.app"
```

Use the packaged app to check the workflow from input selection through export. For navigation or layout changes, check the default window size and both light and dark appearance.

| Check | Command |
| --- | --- |
| Packaged tool catalog | `python3 scripts/check-tool-catalog.py 'build/Mac Utility Kit.app/Contents/MacOS/muk'` |
| Packaged MCP server | `python3 scripts/check-mcp.py 'build/Mac Utility Kit.app/Contents/MacOS/muk'` |

Some integration tests require local executables. See the [CI workflow](.github/workflows/build.yml) for the engine setup and environment variables used in CI.

## Report an issue

Include the app version or commit, macOS version, tool and engine, relevant options, and the steps to reproduce the problem. For export issues, describe the input format and expected output. Share a small sample you have permission to publish and remove personal data, credentials, or private paths from samples and logs.

## Submit a change

- Read the [project conventions](AGENTS.md), [tool specifications](docs/plan/README.md), and [upstream reuse map](docs/reuse/README.md).
- Keep SwiftUI views and workspace navigation in `Sources/MacUtilityKit`. Keep processing and engine adapters in `Sources/UtilityCore`. Reuse those operations from the CLI where applicable.
- When changing a tool, document its inputs, options, engine requirements, and behavior on failure. Verify the app entry point and run the relevant tests. Include what you verified in the pull request.
- When adding a dependency or reusing upstream code, document where it came from and preserve the applicable license notices.

## Build a disk image

Run `./scripts/build-dmg.sh` after building the app to create a verified local preview disk image. The build uses an ad hoc signature by default. For an authorized distribution build, set `MUK_CODESIGN_IDENTITY` to the Developer ID Application identity when running both build scripts. Set `MUK_NOTARY_PROFILE` for the DMG script to submit the final disk image using an authorized Keychain notary profile. The script checks acceptance and staples and validates the ticket before saving the requested disk image. Publication is a separate release step. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

When building a release, set `MUK_BUNDLE_ID` to the distribution bundle identifier, `MUK_RELEASE_VERSION` to the three-part version users see, and `MUK_BUILD_VERSION` to an incrementing build number. `build-app.sh` applies this metadata before signing. Local builds use the preview identifier and version by default. [Apple bundle version documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)

See the [engine release plan](docs/plan/engine-release.md) for the managed engine distribution process.

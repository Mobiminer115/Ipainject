# Validation matrix

## Checks completed before packaging this project

- Parsed every Swift source/test file plus `Package.swift` with the Swift tree-sitter grammar: no error or missing nodes.
- Parsed `project.yml` and the GitHub Actions workflow as YAML.
- Parsed `Info.plist` and every asset-catalog `Contents.json`.
- Verified the app icon is an opaque 1024×1024 RGB PNG.
- Ran repository layout and shell syntax checks.
- Cross-checked the generated Mach-O load-command byte layout with an independent binary-format script.
- Cross-checked the TAR test fixture with an independent TAR reader.
- Searched source and workflow files for unfinished markers, force casts, force tries, embedded signing files and private-key material.

## Checks run by GitHub Actions on macOS

1. `swift test --parallel` executes ForgeCore unit tests.
2. XcodeGen generates the Xcode project from `project.yml`.
3. Xcode resolves the two pinned Swift packages.
4. `xcodebuild` compiles a Debug build for the generic iOS Simulator.
5. `xcodebuild` compiles a Release build for generic iPhone hardware with signing disabled.
6. The packaging script checks `Info.plist`, executable permissions and Mach-O file type.
7. The script creates the unsigned IPA, runs `unzip -t`, verifies the expected executable path and refuses an empty artifact.

The Linux authoring environment does not contain Xcode, so the actual Apple SDK compile is intentionally enforced in the supplied macOS workflow rather than claimed as a local check.

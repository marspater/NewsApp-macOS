# Instructions for the Jules agent

Follow [AGENTS.md](AGENTS.md) for coding-agent workflow. Project technology, architecture and validation requirements are maintained in the contributor documents linked there; do not redefine them in this file.

Keep PRs focused, compare proposed changes with current main, and omit unrelated helper scripts or agent journals from product changes. Report failed checks accurately and do not assume a stale PR failure is caused by its patch.

## Linux environment

Jules runs on Ubuntu Linux without Xcode or the macOS SDK. The app imports SwiftUI, AppKit and FoundationModels, and the tests compile for `arm64-apple-macos15.0`, so `./test.sh`, `build.sh`, `build_release.sh` and `swift build` cannot run there. Run only the Python evaluation scripts that `./test.sh` invokes before compiling. Report Swift builds and tests as not run, never as passed or failed; the GitHub CI and Codemagic macOS runners are the Swift gate.

The default Jules image has no Swift toolchain. When the environment setup installs Swift 6.4 (the Xcode 27 toolchain), run `swiftc -parse` on changed Swift files. This is a syntax-only check: it does not resolve imports or type-check, and it does not replace the macOS checks.

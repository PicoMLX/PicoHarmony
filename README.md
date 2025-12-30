<h1 align="center">Pico Harmony (Swift)</h1>

Swift package that wraps OpenAI's Harmony Rust library via UniFFI and ships a prebuilt `harmony_uniffiFFI.xcframework`. It mirrors the Python API shape for rendering/parsing Harmony-formatted conversations and exposes the full encoding surface in Swift.

## Installation (SwiftPM)

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/<your-org>/PicoHarmony.git", branch: "master"),
],
targets: [
  .target(
    name: "YourApp",
    dependencies: ["Harmony"]
  ),
]
```

The binary target `harmony_uniffiFFI` is checked in under `Binaries/`. If you need to rebuild it (e.g., after updating the Rust submodule), run `scripts/build_uniffi.sh` with a Rust toolchain installed via `rustup` and iOS/macOS targets available.

## Quickstart

```swift
import Harmony

let enc = try HarmonyEncoding(name: .harmonyGptOss)

let convo = Conversation(messages: [
  .init(author: Author(role: .system), content: [.system(SystemContent(modelIdentity: "You are ChatGPT."))]),
  .user("What is 2 + 2?")
])

let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
let parsed = try enc.parseMessagesFromCompletionTokens(tokens, role: .assistant)
print(parsed)
```

Streaming parse example:

```swift
let parser = try StreamableParser(encoding: enc, role: .assistant)
for t in tokens { _ = try await parser.process(t) }
let messages = try await parser.messages()
```

## Project layout

- `Sources/Harmony/` – Swift API surface
- `rust/harmony_uniffi/` – UniFFI bridge code
- `rust/openai-harmony/` – upstream Harmony Rust submodule
- `Binaries/harmony_uniffiFFI.xcframework` – prebuilt static libs + headers
- `Tests/PicoHarmonyTests/` – Swift test suite (parity with Python fixtures)

## Development

- Run tests: `swift test`
- Rebuild XCFramework (if Rust sources change): `./scripts/build_uniffi.sh`

For details on the Harmony format itself, see the upstream project: <https://github.com/openai/harmony>.

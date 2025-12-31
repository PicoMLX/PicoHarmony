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

// Create a system message with defaults (model identity, reasoning effort, channels, etc.)
var sys = try SystemContent.makeDefault()
sys.modelIdentity = "You are a helpful assistant."

let convo = Conversation(messages: [
  Message(author: Author(role: .system), content: [.system(sys)]),
  Message.user("What is 2 + 2?")
])

// Render to tokens for model input
let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)

// Parse model output back to messages
let parsed = try enc.parseMessagesFromCompletionTokens(completionTokens, role: .assistant)
```

## Adding Tools

### Built-in Tools (Browser, Python)

Tool configurations are fetched from Rust to ensure consistency with the canonical implementation:

```swift
var sys = try SystemContent.makeDefault()
sys.conversationStartDate = "2025-01-15"
try sys.withBrowserTool()   // Add web browsing capability
try sys.withPythonTool()    // Add Python code execution

let convo = Conversation(messages: [
  Message(author: Author(role: .system), content: [.system(sys)]),
  Message.user("Search for the latest news about Swift.")
])
```

### Custom Function Tools

Define your own tools in the developer message:

```swift
var sys = try SystemContent.makeDefault()
try sys.withBrowserTool()

// Define custom function parameters
let weatherParams: JSONValue = .object([
  "type": .string("object"),
  "properties": .object([
    "location": .object([
      "type": .string("string"),
      "description": .string("City and state, e.g. San Francisco, CA")
    ])
  ]),
  "required": .array([.string("location")])
])

var dev = DeveloperContent()
dev.instructions = "Help the user with weather information."
dev.withFunctionTools([
  ToolDescription(name: "get_weather", description: "Get current weather for a location", parameters: weatherParams)
])

let convo = Conversation(messages: [
  Message(author: Author(role: .system), content: [.system(sys)]),
  Message(author: Author(role: .developer), content: [.developer(dev)]),
  Message.user("What's the weather in Tokyo?")
])
```

## MLX-Swift / Local Inference

PicoHarmony is designed for use with local LLMs via MLX-Swift or similar frameworks. Typical workflow:

```swift
import Harmony

let enc = try HarmonyEncoding(name: .harmonyGptOss)

// 1. Build your conversation
var sys = try SystemContent.makeDefault()
let convo = Conversation(messages: [
  Message(author: Author(role: .system), content: [.system(sys)]),
  Message.user("Explain quantum computing briefly.")
])

// 2. Render to token IDs for model input
let inputTokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)

// 3. Run inference with your model (MLX-Swift, llama.cpp, etc.)
let outputTokens: [UInt32] = model.generate(inputTokens, maxTokens: 512)

// 4. Parse the completion tokens back to messages
let messages = try enc.parseMessagesFromCompletionTokens(outputTokens, role: .assistant)

// Messages may include:
// - "analysis" channel: model's reasoning/thinking
// - "final" channel: the response shown to the user
// - Tool calls with recipient like "functions.get_weather"
for msg in messages {
  print("Channel: \(msg.channel ?? "none"), Content: \(msg.content)")
}
```

### Streaming Responses

For real-time token-by-token parsing during generation:

```swift
let parser = try StreamableParser(encoding: enc, role: .assistant)

// Feed tokens as they're generated
for token in outputTokens {
  let delta = try await parser.process(token)
  
  // delta.channel - current channel (analysis, commentary, final)
  // delta.delta - new text content
  // delta.recipient - tool being called (e.g., "functions.get_weather")
  
  if let text = delta.delta {
    print(text, terminator: "") // Stream to UI
  }
}

// Get all parsed messages
let messages = try await parser.messages()
```

### Stop Tokens

Get the appropriate stop tokens for generation:

```swift
let stopTokens = try enc.stopTokens()
let actionStopTokens = try enc.stopTokensForAssistantActions() // For tool calls
```

## API Parity with Python

This library mirrors the Python `openai-harmony` API, making it easy to port examples:

| Python | Swift |
|--------|-------|
| `SystemContent.new()` | `SystemContent.makeDefault()` |
| `.with_browser_tool()` | `.withBrowserTool()` |
| `.with_python_tool()` | `.withPythonTool()` |
| `.with_function_tools([...])` | `.withFunctionTools([...])` |
| `load_harmony_encoding(name)` | `HarmonyEncoding(name:)` |
| `StreamableParser(enc, role)` | `StreamableParser(encoding:role:)` |

## Project Layout

- `Sources/Harmony/` – Swift API surface
- `rust/harmony_uniffi/` – UniFFI bridge code
- `rust/openai-harmony/` – upstream Harmony Rust submodule
- `Binaries/harmony_uniffiFFI.xcframework` – prebuilt static libs + headers
- `Tests/PicoHarmonyTests/` – Swift test suite (parity with Python fixtures)

## Development

```bash
# Run tests
swift test

# Rebuild XCFramework (if Rust sources change)
./scripts/build_uniffi.sh
```

For details on the Harmony format itself, see the upstream project: <https://github.com/openai/harmony>.

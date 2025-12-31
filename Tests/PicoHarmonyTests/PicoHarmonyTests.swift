import Foundation
import Testing
@testable import Harmony

// Helpers
private let repoRoot: URL = {
  let fileURL = URL(fileURLWithPath: #filePath)
  return fileURL.deletingLastPathComponent() // PicoHarmonyTests
    .deletingLastPathComponent()            // Tests
    .deletingLastPathComponent()            // PicoHarmony
}()

private let testDataRoot = repoRoot.appendingPathComponent("rust/openai-harmony/test-data", isDirectory: true)

private func readTokens(_ filename: String) throws -> [UInt32] {
  let url = testDataRoot.appendingPathComponent(filename)
  let contents = try String(contentsOf: url, encoding: .utf8)
  return contents.split { $0.isWhitespace }.compactMap { UInt32($0) }
}

private func readText(_ filename: String) throws -> String {
  let url = testDataRoot.appendingPathComponent(filename)
  return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func lineSet(_ text: String) -> Set<String> {
  Set(text.split(separator: "\n").map(String.init))
}

private func functionsNamespace() -> ToolNamespaceConfig {
  let getLocation = ToolDescription(name: "get_location", description: "Gets the location of the user.")

  let getCurrentWeatherParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "location": .object([
        "type": .string("string"),
        "description": .string("The city and state, e.g. San Francisco, CA"),
      ]),
      "format": .object([
        "type": .string("string"),
        "enum": .array([.string("celsius"), .string("fahrenheit")]),
        "default": .string("celsius"),
      ]),
    ]),
    "required": .array([.string("location")]),
  ])
  let getCurrentWeather = ToolDescription(name: "get_current_weather",
                                          description: "Gets the current weather in the provided location.",
                                          parameters: getCurrentWeatherParams)

  let getMultipleWeathersParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "locations": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("List of city and state, e.g. [\"San Francisco, CA\", \"New York, NY\"]"),
      ]),
      "format": .object([
        "type": .string("string"),
        "enum": .array([.string("celsius"), .string("fahrenheit")]),
        "default": .string("celsius"),
      ]),
    ]),
    "required": .array([.string("locations")]),
  ])
  let getMultipleWeathers = ToolDescription(name: "get_multiple_weathers",
                                            description: "Gets the current weather in the provided list of locations.",
                                            parameters: getMultipleWeathersParams)

  let lookupWeatherParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "location": .object(["type": .string("string")]),
    ]),
    "required": .array([.string("location")]),
  ])
  let lookupWeather = ToolDescription(name: "lookup_weather",
                                      description: "Use this tool to lookup the weather in a given location. Call it with the parameter 'location', can be any textual description of a location.",
                                      parameters: lookupWeatherParams)

  let kitchenSinkParams: JSONValue = .object([
    "description": .string("params object"),
    "type": .string("object"),
    "properties": .object([
      "string": .object([
        "type": .string("string"),
        "title": .string("STRING"),
        "description": .string("A string"),
        "examples": .array([.string("hello"), .string("world")]),
      ]),
      "string_nullable": .object([
        "type": .string("string"),
        "nullable": .bool(true),
        "description": .string("A nullable string"),
        "default": .string("the default"),
      ]),
      "string_enum": .object([
        "type": .string("string"),
        "enum": .array([.string("a"), .string("b"), .string("c")]),
      ]),
      "oneof_string_or_number": .object([
        "oneOf": .array([
          .object(["type": .string("string"), "default": .string("default_string_in_oneof")]),
          .object(["type": .string("number"), "description": .string("numbers can happen too")]),
        ]),
        "description": .string("a oneof"),
        "default": .number(20),
      ]),
    ]),
  ])
  let kitchenSink = ToolDescription(name: "kitchensink",
                                    description: "A function with various complex schemas.",
                                    parameters: kitchenSinkParams)

  return ToolNamespaceConfig(name: "functions", description: nil, tools: [getLocation, getCurrentWeather, getMultipleWeathers, lookupWeather, kitchenSink])
}

private func browserNamespace() -> ToolNamespaceConfig {
  let browserDesc = """
Tool for browsing.
The `cursor` appears in brackets before each browsing display: `[{cursor}]`.
Cite information from the tool using the following format:
`【{cursor}†L{line_start}(-L{line_end})?】`, for example: `` or ``.
Do not quote more than 10 words directly from the tool output.
sources=web (default: web)
"""
  let searchParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "query": .object(["type": .string("string")]),
      "topn": .object(["type": .string("number"), "default": .number(10)]),
      "source": .object(["type": .string("string")]),
    ]),
    "required": .array([.string("query")]),
  ])
  let openParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "id": .object(["type": .array([.string("number"), .string("string")]), "default": .number(-1)]),
      "cursor": .object(["type": .string("number"), "default": .number(-1)]),
      "loc": .object(["type": .string("number"), "default": .number(-1)]),
      "num_lines": .object(["type": .string("number"), "default": .number(-1)]),
      "view_source": .object(["type": .string("boolean"), "default": .bool(false)]),
      "source": .object(["type": .string("string")]),
    ]),
  ])
  let findParams: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "pattern": .object(["type": .string("string")]),
      "cursor": .object(["type": .string("number"), "default": .number(-1)]),
    ]),
    "required": .array([.string("pattern")]),
  ])

  let openDesc = """
Opens the link `id` from the page indicated by `cursor` starting at line number `loc`, showing `num_lines` lines.
Valid link ids are displayed with the formatting: `【{id}†.*】`.
If `cursor` is not provided, the most recent page is implied.
If `id` is a string, it is treated as a fully qualified URL associated with `source`.
If `loc` is not provided, the viewport will be positioned at the beginning of the document or centered on the most relevant passage, if available.
Use this function without `id` to scroll to a new location of an opened page.
"""
  let search = ToolDescription(name: "search", description: "Searches for information related to `query` and displays `topn` results.", parameters: searchParams)
  let open = ToolDescription(name: "open", description: openDesc, parameters: openParams)
  let find = ToolDescription(name: "find", description: "Finds exact matches of `pattern` in the current page, or the page given by `cursor`.", parameters: findParams)
  return ToolNamespaceConfig(name: "browser", description: browserDesc, tools: [search, open, find])
}

private func pythonNamespace() -> ToolNamespaceConfig {
  let desc = """
Use this tool to execute Python code in your chain of thought. The code will not be shown to the user. This tool should be used for internal reasoning, but not for code that is intended to be visible to the user (e.g. when creating plots, tables, or files).

When you send a message containing Python code to python, it will be executed in a stateful Jupyter notebook environment. python will respond with the output of the execution or time out after 120.0 seconds. The drive at '/mnt/data' can be used to save and persist user files. Internet access for this session is UNKNOWN. Depends on the cluster.
"""
  return ToolNamespaceConfig(name: "python", description: desc, tools: [])
}

private func assertMessage(_ actual: Message, equals expected: Message) {
  #expect(actual.author.role == expected.author.role, "author.role")
  #expect(actual.author.name == expected.author.name, "author.name")
  #expect(actual.channel == expected.channel, "channel")
  #expect(actual.recipient == expected.recipient, "recipient")
  #expect(actual.contentType == expected.contentType, "contentType")
  #expect(actual.content.count == expected.content.count, "content count")
  for (idx, (a, e)) in zip(actual.content, expected.content).enumerated() {
    switch (a, e) {
    case let (.text(at), .text(et)):
      #expect(at.text == et.text, "content[\(idx)] text")
    default:
      #expect(Bool(false), "content[\(idx)] kind mismatch: \(a) vs \(e)")
    }
  }
}

@Suite struct HarmonyEncodingTests {
  let enc = try! HarmonyEncoding(name: .harmonyGptOss)

  @Test func simpleConversationMatchesFixture() throws {
    let expectedText = try readText("test_simple_convo.txt")
    let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(SystemContent(modelIdentity: "You are ChatGPT, a large language model trained by OpenAI."))]),
      Message.user("What is 2 + 2?")
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokens == expectedTokens)
    #expect(try enc.decodeUtf8(tokens) == expectedText)
  }

  @Test func simpleConversationWithEffortVariants() throws {
    let cases: [(ReasoningEffort, String, Bool)] = [
      (.low, "test_simple_convo_low_effort.txt", true),
      (.medium, "test_simple_convo_medium_effort.txt", true),
      (.high, "test_simple_convo_high_effort.txt", true),
      (.low, "test_simple_convo_low_effort_no_instruction.txt", false),
      (.medium, "test_simple_convo_medium_effort_no_instruction.txt", false),
      (.high, "test_simple_convo_high_effort_no_instruction.txt", false),
    ]

    for (effort, fixture, includeDev) in cases {
      let expectedText = try readText(fixture)
      let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

      var sys = SystemContent()
      sys.modelIdentity = "You are ChatGPT, a large language model trained by OpenAI."
      sys.reasoningEffort = effort

      var messages: [Message] = [Message(author: Author(role: .system), content: [.system(sys)])]
      if includeDev {
        var dev = DeveloperContent()
        dev.instructions = "Answer the user's questions like a robot."
        messages.append(Message(author: Author(role: .developer), content: [.developer(dev)]))
      }
      messages.append(Message.user("What is the capital of the largest country in the world?"))

      let convo = Conversation(messages: messages)
      let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
      #expect(tokens == expectedTokens)
    }
  }

  @Test func simpleReasoningResponseParsesAndRoundTrips() throws {
    let tokens = try readTokens("test_simple_reasoning_response.txt")
    let messages = try enc.parseMessagesFromCompletionTokens(tokens, role: .assistant)
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("User asks: \"What is 2 + 2?\" Simple arithmetic. Provide answer."))],
              channel: "analysis",
              recipient: nil,
              contentType: nil),
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("2 + 2 = 4."))],
              channel: "final",
              recipient: nil,
              contentType: nil),
    ]
    #expect(messages.count == expected.count)
    zip(messages, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func simpleToolCallParsesAndRoundTrips() throws {
    let tokens = try readTokens("test_simple_tool_call.txt")
    let messages = try enc.parseMessagesFromCompletionTokens(tokens, role: .assistant)
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("User asks: \"What is the weather in Tokyo?\" We need to use lookup_weather tool."))],
              channel: "analysis",
              recipient: nil,
              contentType: nil),
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("{\"location\": \"Tokyo\"}"))],
              channel: "analysis",
              recipient: "lookup_weather",
              contentType: "code"),
    ]
    #expect(messages.count == expected.count)
    zip(messages, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func reasoningSystemMessageRenders() throws {
    let expectedText = try readText("test_reasoning_system_message.txt")
    let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

    var sys = SystemContent()
    sys.modelIdentity = "You are ChatGPT, a large language model trained by OpenAI."
    sys.reasoningEffort = .medium
    sys.channelConfig = .requireChannels(["analysis", "final"])

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(sys)]),
      Message.user("What is 2 + 2?")
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokens == expectedTokens)
  }

  @Test func reasoningSystemMessageNoInstruction() throws {
    let expectedText = try readText("test_reasoning_system_message_no_instruction.txt")
    let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

    var sys = SystemContent()
    sys.modelIdentity = "You are ChatGPT, a large language model trained by OpenAI."
    sys.reasoningEffort = .high
    sys.channelConfig = .requireChannels(["analysis", "final"])

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(sys)]),
      Message.user("What is the best place to eat candy in the world?"),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokens == expectedTokens)
  }

  @Test func reasoningSystemMessageWithDates() throws {
    let expectedText = try readText("test_reasoning_system_message_with_dates.txt")
    let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

    var sys = SystemContent()
    sys.modelIdentity = "You are ChatGPT, a large language model trained by OpenAI."
    sys.reasoningEffort = .medium
    sys.conversationStartDate = "2021-01-01"
    sys.knowledgeCutoff = "2021-01"
    sys.channelConfig = .requireChannels(["analysis", "final"])

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(sys)]),
      Message.user("What is 42 * pi?"),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokens == expectedTokens)
  }

  @Test func toolCallWithConstrainTokenizedCorrectly() throws {
    let text = "<|start|>assistant to=functions.get_weather<|channel|>commentary <|constrain|>json<|message|>{\"location\": \"Tokyo\"}<|call|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    let parsed = try enc.parseMessagesFromCompletionTokens(tokens, role: nil)
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("{\"location\": \"Tokyo\"}"))],
              channel: "commentary",
              recipient: "functions.get_weather",
              contentType: "<|constrain|>json"),
    ]
    #expect(parsed.count == expected.count)
    zip(parsed, expected).forEach { assertMessage($0.0, equals: $0.1) }
    let decoded = try enc.decodeUtf8(tokens)
    #expect(decoded == text)
    let roundtrip = try enc.renderConversation(Conversation(messages: expected))
    #expect(roundtrip == tokens)
  }

  @Test func toolCallWithConstrainMarkerAdjacent() throws {
    let text = "<|start|>assistant to=functions.get_weather<|channel|>commentary<|constrain|>json<|message|>{\"location\": \"Tokyo\"}<|call|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    let parsed = try enc.parseMessagesFromCompletionTokens(tokens, role: nil)
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("{\"location\": \"Tokyo\"}"))],
              channel: "commentary",
              recipient: "functions.get_weather",
              contentType: "<|constrain|>json"),
    ]
    #expect(parsed.count == expected.count)
    zip(parsed, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func toolCallChannelBeforeRecipientAndConstrainAdjacent() throws {
    let text = "<|start|>assistant<|channel|>commentary to=functions.get_weather<|constrain|>json<|message|>{\"latitude\":48.8566,\"longitude\":2.3522}<|call|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    let parsed = try enc.parseMessagesFromCompletionTokens(tokens, role: nil)
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("{\"latitude\":48.8566,\"longitude\":2.3522}"))],
              channel: "commentary",
              recipient: "functions.get_weather",
              contentType: "<|constrain|>json"),
    ]
    #expect(parsed.count == expected.count)
    zip(parsed, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func renderFunctionsWithParameters() throws {
    let expectedText = try readText("test_render_functions_with_parameters.txt")

    var sys = SystemContent()
    sys.reasoningEffort = .high
    sys.conversationStartDate = "2025-06-28"
    sys.channelConfig = .requireChannels(["analysis", "commentary", "final"])
    sys.tools = ["browser": browserNamespace()]

    var dev = DeveloperContent()
    dev.instructions = "Always respond in riddles"
    dev.tools = ["functions": functionsNamespace()]

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(sys)]),
      Message(author: Author(role: .developer), content: [.developer(dev)]),
      Message.user("What is the weather like in SF?"),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    let rendered = try enc.decodeUtf8(tokens)
    #expect(rendered == expectedText)
  }

  @Test func renderNoTools() throws {
    let expectedText = try readText("test_no_tools.txt")
    let expectedTokens = try enc.encode(expectedText, policy: .allowAll)

    var sys = SystemContent()
    sys.reasoningEffort = .medium
    sys.conversationStartDate = "2025-06-28"

    let convo = Conversation(messages: [Message(author: Author(role: .system), content: [.system(sys)])])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokens == expectedTokens)
    let rendered = try enc.decodeUtf8(tokens)
    #expect(rendered == expectedText)
  }

  @Test func renderBrowserToolOnly() throws {
    let expectedText = try readText("test_browser_tool_only.txt")

    var sys = SystemContent()
    sys.reasoningEffort = .medium
    sys.conversationStartDate = "2025-06-28"
    sys.channelConfig = .requireChannels(["analysis", "commentary", "final"])
    sys.tools = ["browser": browserNamespace()]

    let convo = Conversation(messages: [Message(author: Author(role: .system), content: [.system(sys)])])
    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    let rendered = try enc.decodeUtf8(tokens)
    #expect(rendered == expectedText)
  }

  @Test func renderBrowserAndFunctionTool() throws {
    let expectedText = try readText("test_browser_and_function_tool.txt")

    var sys = SystemContent()
    sys.reasoningEffort = .medium
    sys.conversationStartDate = "2025-06-28"
    sys.channelConfig = .requireChannels(["analysis", "commentary", "final"])
    sys.tools = ["browser": browserNamespace()]

    var dev = DeveloperContent()
    dev.tools = ["functions": functionsNamespace()]

    let convo = Conversation(messages: [
      Message(author: Author(role: .system), content: [.system(sys)]),
      Message(author: Author(role: .developer), content: [.developer(dev)]),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    let rendered = try enc.decodeUtf8(tokens)
    #expect(rendered == expectedText)
  }

  @Test func renderBrowserAndPythonTool() throws {
    let expectedText = try readText("test_browser_and_python_tool.txt")

    var sys = SystemContent()
    sys.reasoningEffort = .medium
    sys.conversationStartDate = "2025-06-28"
    sys.channelConfig = .requireChannels(["analysis", "commentary", "final"])
    sys.tools = [
      "browser": browserNamespace(),
      "python": pythonNamespace(),
    ]

    let convo = Conversation(messages: [Message(author: Author(role: .system), content: [.system(sys)])])
    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    let rendered = try enc.decodeUtf8(tokens)
    #expect(rendered == expectedText)
  }

  @Test func renderConversationForTrainingFinalChannel() throws {
    let convo = Conversation(messages: [
      Message.user("hi"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("hello"))], channel: "final")
    ])

    let training = try enc.renderConversationForTraining(convo)
    let regular = try enc.renderConversation(convo)

    #expect(training.count == regular.count)
    #expect(training.dropLast() == regular.dropLast())

    let tokenReturn = try enc.encode("<|return|>", policy: .allow(["<|return|>"])).first
    let tokenEnd = try enc.encode("<|end|>", policy: .allow(["<|end|>"])).first
    #expect(regular.last == tokenEnd)
    #expect(training.last == tokenReturn)
  }

  @Test func renderAndRenderConversationRoundtrip() throws {
    let msg = Message.user("Hello")
    let convo = Conversation(messages: [msg])

    let tokensMsg = try enc.render(msg)
    let tokensConvo = try enc.renderConversation(convo)
    #expect(tokensMsg == tokensConvo)

    let tokensCompletion = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant)
    #expect(tokensCompletion.prefix(tokensConvo.count).elementsEqual(tokensConvo))
  }

  @Test func renderConversationForTrainingNonFinal() throws {
    let convo = Conversation(messages: [Message.user("hi")])
    let training = try enc.renderConversationForTraining(convo)
    let regular = try enc.renderConversation(convo)
    #expect(training == regular)
  }

  @Test func droppingCoTByDefault() throws {
    let expectedText = try readText("test_dropping_cot_by_default.txt")
    let convo = Conversation(messages: [
      Message.user("What is 2 + 2?"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("User asks: “What is 2 + 2?” Simple arithmetic. Provide answer."))], channel: "analysis"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("2 + 2 equals 4."))], channel: "final"),
      Message.user("What about 9 / 2?"),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant, config: RenderConversationConfig(autoDropAnalysis: true))
    #expect(try enc.decodeUtf8(tokens) == expectedText)
  }

  @Test func doesNotDropIfOngoingAnalysis() throws {
    let expectedText = try readText("test_does_not_drop_if_ongoing_analysis.txt")
    let convo = Conversation(messages: [
      Message.user("What is the weather in SF?"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("User asks: “What is the weather in SF?” We need to use lookup_weather tool."))], channel: "analysis"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("{\"location\": \"San Francisco\"}"))], channel: "commentary", recipient: "functions.lookup_weather", contentType: "<|constrain|>json"),
      Message(author: Author(role: .tool, name: "functions.lookup_weather"), content: [.text(TextContent("{\"temperature\": 20, \"description\": \"sunny\"}"))]),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant, config: RenderConversationConfig(autoDropAnalysis: true))
    #expect(try enc.decodeUtf8(tokens) == expectedText)
    #expect(try enc.encode(expectedText, policy: .allowAll) == tokens)
  }

  @Test func preserveCoT() throws {
    let expectedText = try readText("test_preserve_cot.txt")
    let convo = Conversation(messages: [
      Message.user("What is 2 + 2?"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("User asks a simple question: \"What is 2 + 2?\" The answer: 4."))], channel: "analysis"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("2 + 2 equals 4."))], channel: "final"),
      Message.user("What about 9 / 2?"),
    ])

    let tokens = try enc.renderConversationForCompletion(convo, nextTurnRole: .assistant, config: RenderConversationConfig(autoDropAnalysis: false))
    #expect(try enc.decodeUtf8(tokens) == expectedText)
  }

  @Test func keepAnalysisBetweenFinalMessages() throws {
    let expectedText = try readText("test_keep_analysis_between_finals.txt")
    let convo = Conversation(messages: [
      Message.user("What is 2 + 2?"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("thinking 2+2"))], channel: "analysis"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("4"))], channel: "final"),
      Message.user("What is 3 + 5?"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("thinking 3+5"))], channel: "analysis"),
      Message(author: Author(role: .assistant), content: [.text(TextContent("8"))], channel: "final"),
    ])

    let tokens = try enc.renderConversation(convo)
    #expect(try enc.decodeUtf8(tokens) == expectedText)
  }

  @Test func toolResponseParsing() throws {
    let expectedText = try readText("test_tool_response_parsing.txt")
    let expectedMessage = Message(author: Author(role: .tool, name: "browser.search"),
                                  content: [.text(TextContent("{\"result\": \"https://openai.com/\"}"))],
                                  channel: "commentary",
                                  recipient: "assistant")

    var tokens = try enc.render(expectedMessage)
    tokens.removeLast() // drop <|end|>

    let messages = try enc.parseMessagesFromCompletionTokens(Array(tokens), role: nil)
    #expect(messages.count == 1)
    assertMessage(messages[0], equals: expectedMessage)
    #expect(try enc.decodeUtf8(Array(tokens)) == expectedText)
  }

  @Test func encodeDecodeRoundtrip() throws {
    let text = "hello world"
    let tokens = try enc.encode(text)
    #expect(try enc.decodeUtf8(tokens) == text)
    #expect(try enc.decode(tokens) == text)
  }

  @Test func encodeAllowedSpecial() throws {
    #expect(try enc.encode("hello world") == [24912, 2375])
    #expect(try enc.encode("<|start|>", policy: .allow(["<|start|>" ])) == [200006])
    #expect(try enc.encode("<|start|>", policy: .allowAll) == [200006])
    do {
      _ = try enc.encode("<|start|>")
      Issue.record("Expected disallowed special token to throw")
    } catch let err as HarmonyError {
      if case .Msg(let msg) = err {
        #expect(msg.contains("Encountered disallowed special token"))
      } else { Issue.record("Unexpected error case: \(err)") }
    }
    #expect(try enc.encode("<|start|>", policy: .disableChecks) == [27, 91, 5236, 91, 29])
  }

  @Test func isSpecialToken() throws {
    #expect(enc.isSpecialToken(200006))
    #expect(!enc.isSpecialToken(24912))
  }

  @Test func reservedTokenDecoding() throws {
    #expect(try enc.decodeUtf8([200014]) == "<|reserved_200014|>")
    #expect(try enc.decodeUtf8([201088]) == "<|reserved_201088|>")
  }

  @Test func invalidUtf8Decoding() throws {
    do {
      _ = try enc.decodeUtf8([99999999])
      Issue.record("Expected invalid token decode to throw")
    } catch let err as HarmonyError {
      if case .Msg(let msg) = err {
        #expect(msg.contains("Invalid token for decoding: 99999999"))
      } else { Issue.record("Unexpected error case: \(err)") }
    }

    let invalidBytes = [UInt32(132990), UInt32(9552)]
    do {
      _ = try enc.decodeUtf8(invalidBytes)
      Issue.record("Expected invalid utf-8 to throw")
    } catch let err as HarmonyError {
      if case .Msg(let msg) = err {
        #expect(msg.contains("Invalid utf-8"))
      } else { Issue.record("Unexpected error case: \(err)") }
    }

    let replaced = try enc.decode(invalidBytes, errors: .replace)
    #expect(replaced.contains("Chicken"))
  }

  @Test func streamableParserSimple() async throws {
    let text = try readText("test_streamable_parser.txt")
    let tokens = try enc.encode(text, policy: .allowAll)
    let parser = try StreamableParser(encoding: enc, role: .assistant)
    for t in tokens { _ = try await parser.process(t) }
    let msgs = try await parser.messages()
    #expect(msgs.count == 3)
  }

  @Test func streamableParserToolCallWithConstrainAdjacent() async throws {
    let text = "<|start|>assistant<|channel|>commentary to=functions.get_weather<|constrain|>json<|message|>{\"latitude\":48.8566,\"longitude\":2.3522}<|call|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    let parser = try StreamableParser(encoding: enc, role: nil)
    for t in tokens { _ = try await parser.process(t) }
    let msgs = try await parser.messages()
    let expected = [
      Message(author: Author(role: .assistant),
              content: [.text(TextContent("{\"latitude\":48.8566,\"longitude\":2.3522}"))],
              channel: "commentary",
              recipient: "functions.get_weather",
              contentType: "<|constrain|>json")
    ]
    #expect(msgs.count == expected.count)
    zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func streamableParserMissingMessageToken() async throws {
    let text = "I must refuse<|end|><|start|>assistant<|channel|>analysis<|message|>We must refuse<|end|><|start|>assistant<|channel|>final<|message|>I'm sorry, but I can't help with that.<|return|>"
    let tokens = try enc.encode(text, policy: .allowAll)

    for strict in [false, true] {
      let parser = try StreamableParser(encoding: enc, role: .assistant, strict: strict)
      if strict {
        var threw = false
        do { for t in tokens { _ = try await parser.process(t) } } catch let err as HarmonyError {
          threw = err.localizedDescription.contains("unexpected tokens remaining in message header")
        }
        #expect(threw)
      } else {
        for t in tokens { _ = try await parser.process(t) }
        let msgs = try await parser.messages()
        let expected = [
          Message(author: Author(role: .assistant), content: [.text(TextContent("I must refuse"))]),
          Message(author: Author(role: .assistant), content: [.text(TextContent("We must refuse"))], channel: "analysis"),
          Message(author: Author(role: .assistant), content: [.text(TextContent("I'm sorry, but I can't help with that."))], channel: "final"),
        ]
        #expect(msgs.count == expected.count)
        zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
      }
    }
  }

  @Test func streamableParserMissingMessageTokenOtherInitialHeaders() async throws {
    let text = "<|channel|>analysis I must refuse<|end|><|start|>assistant<|channel|>analysis<|message|>We must refuse<|end|><|start|>assistant<|channel|>final<|message|>I'm sorry, but I can't help with that.<|return|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    for strict in [false, true] {
      let parser = try StreamableParser(encoding: enc, role: .assistant, strict: strict)
      if strict {
        var threw = false
        do { for t in tokens { _ = try await parser.process(t) } } catch let err as HarmonyError {
          threw = err.localizedDescription.contains("unexpected tokens remaining in message header")
        }
        #expect(threw)
      } else {
        for t in tokens { _ = try await parser.process(t) }
        let msgs = try await parser.messages()
        let expected = [
          Message(author: Author(role: .assistant), content: [.text(TextContent("I must refuse"))], channel: "analysis"),
          Message(author: Author(role: .assistant), content: [.text(TextContent("We must refuse"))], channel: "analysis"),
          Message(author: Author(role: .assistant), content: [.text(TextContent("I'm sorry, but I can't help with that."))], channel: "final"),
        ]
        #expect(msgs.count == expected.count)
        zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
      }
    }
  }

  @Test func streamableParserMissingMessageTokenToolCall() async throws {
    let text = "... Let's use the tool.<|end|><|start|>assistant to=functions.get_weather<|channel|>commentary json<|message|>{\"location\": \"Tokyo\"}<|call|>"
    let tokens = try enc.encode(text, policy: .allowAll)
    for strict in [false, true] {
      let parser = try StreamableParser(encoding: enc, role: .assistant, strict: strict)
      if strict {
        var threw = false
        do { for t in tokens { _ = try await parser.process(t) } } catch let err as HarmonyError {
          threw = err.localizedDescription.contains("unexpected tokens remaining in message header")
        }
        #expect(threw)
      } else {
        for t in tokens { _ = try await parser.process(t) }
        let msgs = try await parser.messages()
        let expected = [
          Message(author: Author(role: .assistant), content: [.text(TextContent("... Let's use the tool."))]),
          Message(author: Author(role: .assistant), content: [.text(TextContent("{\"location\": \"Tokyo\"}"))], channel: "commentary", recipient: "functions.get_weather", contentType: "json"),
        ]
        #expect(msgs.count == expected.count)
        zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
      }
    }
  }

  @Test func streamableParserInvalidUtf8Decoding() async throws {
    let invalidTokenSequence: [UInt32] = [9552, 9552]
    #expect(throws: HarmonyError.self) { try self.enc.decodeUtf8(invalidTokenSequence) }

    let prefix = try enc.encode("<|start|>assistant<|message|>", policy: .allowAll)
    let suffix = try enc.encode("worked<|end|>", policy: .allowAll)
    let tokens = prefix + invalidTokenSequence + suffix
    let parser = try StreamableParser(encoding: enc, role: nil)
    for t in tokens { _ = try await parser.process(t) }
    let msgs = try await parser.messages()
    let expected = [Message(author: Author(role: .assistant), content: [.text(TextContent(" \u{FFFD} \u{FFFD}worked"))])]
    #expect(msgs.count == expected.count)
    zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func streamableParserInvalidUtf8DecodingSplitAcrossTokens() async throws {
    let valid = try enc.encode("XY")
    #expect(try enc.decodeUtf8(valid) == "XY")
    let invalidSeq: [UInt32] = [9552] + valid
    #expect(throws: HarmonyError.self) { try self.enc.decodeUtf8(invalidSeq) }

    let prefix = try enc.encode("<|start|>assistant<|message|>", policy: .allowAll)
    let suffix = try enc.encode("<|end|>", policy: .allowAll)
    let tokens = prefix + invalidSeq + suffix
    let parser = try StreamableParser(encoding: enc, role: nil)
    for t in tokens { _ = try await parser.process(t) }
    let msgs = try await parser.messages()
    let expected = [Message(author: Author(role: .assistant), content: [.text(TextContent(" \u{FFFD}XY"))])]
    #expect(msgs.count == expected.count)
    zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func streamableParserInvalidUtf8DecodingMultiByteToken() async throws {
    let valid = try enc.encode(" interesting")
    #expect(try enc.decodeUtf8(valid) == " interesting")
    let invalidSeq: [UInt32] = [9552] + valid
    #expect(throws: HarmonyError.self) { try self.enc.decodeUtf8(invalidSeq) }

    let prefix = try enc.encode("<|start|>assistant<|message|>", policy: .allowAll)
    let suffix = try enc.encode("<|end|>", policy: .allowAll)
    let tokens = prefix + invalidSeq + suffix
    let parser = try StreamableParser(encoding: enc, role: nil)
    for t in tokens { _ = try await parser.process(t) }
    let msgs = try await parser.messages()
    let expected = [Message(author: Author(role: .assistant), content: [.text(TextContent(" \u{FFFD} interesting"))])]
    #expect(msgs.count == expected.count)
    zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
  }

  @Test func streamableParserInvalidUtf8DecodingMultiByteTokenNoEosMarker() async throws {
    let valid = try enc.encode(" interesting")
    #expect(try enc.decodeUtf8(valid) == " interesting")
    let invalidSeq: [UInt32] = [9552] + valid
    #expect(throws: HarmonyError.self) { try self.enc.decodeUtf8(invalidSeq) }

    let prefix = try enc.encode("<|start|>assistant<|message|>", policy: .allowAll)
    let suffix = try enc.encode(" story")
    let tokens = prefix + invalidSeq + suffix
    let parser = try StreamableParser(encoding: enc, role: nil)

    var deltas: [String] = []
    for t in tokens {
      let delta = try await parser.process(t)
      if let d = delta.delta { deltas.append(d) }
    }

    let current = try await parser.currentContent()
    #expect(current == " \u{FFFD} interesting story")
    #expect(deltas.joined() == " \u{FFFD} interesting story")

    let oneMore = try enc.encode("Y")[0]
    let delta = try await parser.process(oneMore)
    #expect(delta.delta == "Y")
    #expect(try await parser.currentContent() == " \u{FFFD} interesting storyY")
  }

  @Test func streamableParserTrickyUtf8Decoding() async throws {
    let tricky = "Hello Müller, Γειά σου, Привет, שלום, مرحبا, नमस्ते, こんにちは, 안녕하세요, 你好. Normalized (naïve) vs. decomposed (naïve) characters. Some emojis: 😊👋🏾👨‍👩‍👧‍👦🇺🇸."
    let validSeq = try enc.encode(tricky)

    let prefix = try enc.encode("<|start|>assistant<|message|>", policy: .allowAll)
    let suffix = try enc.encode("<|end|>", policy: .allowAll)
    let tokens = prefix + validSeq + suffix
    let parser = try StreamableParser(encoding: enc, role: nil)

    var deltas: [String] = []
    for t in tokens {
      let delta = try await parser.process(t)
      if let d = delta.delta { deltas.append(d) }
    }

    let msgs = try await parser.messages()
    let expected = [Message(author: Author(role: .assistant), content: [.text(TextContent(tricky))])]
    #expect(msgs.count == expected.count)
    zip(msgs, expected).forEach { assertMessage($0.0, equals: $0.1) }
    #expect(deltas.joined() == tricky)
  }
}

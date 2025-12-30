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
}

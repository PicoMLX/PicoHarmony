import Foundation
import HarmonyUniFFI

// MARK: - Errors

public typealias HarmonyError = PicoHarmonyError

// MARK: - Core types (parity with Python __all__)

public enum Role: String, Codable, Sendable {
  case user, assistant, system, developer, tool
}

public struct Author: Codable, Sendable {
  public var role: Role
  public var name: String?

  public init(role: Role, name: String? = nil) {
    self.role = role
    self.name = name
  }
}

public struct TextContent: Codable, Sendable {
  public var text: String
  public init(_ text: String) { self.text = text }
}

public struct ToolDescription: Codable, Sendable {
  public var name: String
  public var description: String
  public var parameters: JSONValue?

  public init(name: String, description: String, parameters: JSONValue? = nil) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public enum ReasoningEffort: String, Codable, Sendable {
  case low = "Low"
  case medium = "Medium"
  case high = "High"
}

public struct ChannelConfig: Codable, Sendable {
  public var validChannels: [String]
  public var channelRequired: Bool

  public init(validChannels: [String], channelRequired: Bool) {
    self.validChannels = validChannels
    self.channelRequired = channelRequired
  }

  public static func requireChannels(_ channels: [String]) -> ChannelConfig {
    ChannelConfig(validChannels: channels, channelRequired: true)
  }
}

public struct ToolNamespaceConfig: Codable, Sendable {
  public var name: String
  public var description: String?
  public var tools: [ToolDescription]

  public init(name: String, description: String? = nil, tools: [ToolDescription]) {
    self.name = name
    self.description = description
    self.tools = tools
  }
}

public struct SystemContent: Codable, Sendable {
  public var modelIdentity: String? = "You are ChatGPT, a large language model trained by OpenAI."
  public var reasoningEffort: ReasoningEffort? = .medium
  public var conversationStartDate: String? = nil
  public var knowledgeCutoff: String? = "2024-06"
  public var channelConfig: ChannelConfig? = .requireChannels(["analysis", "commentary", "final"])
  public var tools: [String: ToolNamespaceConfig]? = nil

  public init(modelIdentity: String? = nil,
              reasoningEffort: ReasoningEffort? = .medium,
              conversationStartDate: String? = nil,
              knowledgeCutoff: String? = "2024-06",
              channelConfig: ChannelConfig? = .requireChannels(["analysis", "commentary", "final"]),
              tools: [String: ToolNamespaceConfig]? = nil) {
    self.modelIdentity = modelIdentity ?? self.modelIdentity
    self.reasoningEffort = reasoningEffort
    self.conversationStartDate = conversationStartDate
    self.knowledgeCutoff = knowledgeCutoff
    self.channelConfig = channelConfig
    self.tools = tools
  }
}

public struct DeveloperContent: Codable, Sendable {
  public var instructions: String?
  public var tools: [String: ToolNamespaceConfig]?

  public init(instructions: String? = nil, tools: [String: ToolNamespaceConfig]? = nil) {
    self.instructions = instructions
    self.tools = tools
  }
}

public enum Content: Codable, Sendable {
  case text(TextContent)
  case system(SystemContent)
  case developer(DeveloperContent)

  private enum CodingKeys: String, CodingKey { case type, text }
  private enum ContentType: String { case text = "text", system = "system_content", developer = "developer_content" }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch ContentType(rawValue: type) {
    case .text:
      let text = try container.decode(String.self, forKey: .text)
      self = .text(TextContent(text))
    case .system:
      self = .system(try SystemContent(from: decoder))
    case .developer:
      self = .developer(try DeveloperContent(from: decoder))
    case .none:
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown content type \(type)"))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let t):
      try container.encode(ContentType.text.rawValue, forKey: .type)
      try container.encode(t.text, forKey: .text)
    case .system(let sys):
      try container.encode(ContentType.system.rawValue, forKey: .type)
      try sys.encode(to: encoder)
    case .developer(let dev):
      try container.encode(ContentType.developer.rawValue, forKey: .type)
      try dev.encode(to: encoder)
    }
  }
}

public struct Message: Codable, Sendable {
  public var author: Author
  public var content: [Content]
  public var channel: String?
  public var recipient: String?
  public var contentType: String?

  public init(author: Author,
              content: [Content],
              channel: String? = nil,
              recipient: String? = nil,
              contentType: String? = nil) {
    self.author = author
    self.content = content
    self.channel = channel
    self.recipient = recipient
    self.contentType = contentType
  }

  public static func user(_ text: String) -> Message {
    Message(author: Author(role: .user), content: [.text(TextContent(text))])
  }

  public static func assistant(_ text: String) -> Message {
    Message(author: Author(role: .assistant), content: [.text(TextContent(text))])
  }

  private enum CodingKeys: String, CodingKey { case role, name, content, channel, recipient, contentType = "content_type" }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let role = try container.decode(Role.self, forKey: .role)
    let name = try container.decodeIfPresent(String.self, forKey: .name)

    if let contentString = try? container.decode(String.self, forKey: .content) {
      self.content = [.text(TextContent(contentString))]
    } else {
      self.content = try container.decode([Content].self, forKey: .content)
    }

    self.author = Author(role: role, name: name)
    self.channel = try container.decodeIfPresent(String.self, forKey: .channel)
    self.recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
    self.contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(author.role, forKey: .role)
    try container.encodeIfPresent(author.name, forKey: .name)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(channel, forKey: .channel)
    try container.encodeIfPresent(recipient, forKey: .recipient)
    try container.encodeIfPresent(contentType, forKey: .contentType)
  }
}

public struct Conversation: Codable, Sendable {
  public var messages: [Message]
  public init(messages: [Message]) { self.messages = messages }
}

// MARK: - Render/parse options

public struct RenderConversationConfig: Sendable, Codable {
  public var autoDropAnalysis: Bool = true
  public init(autoDropAnalysis: Bool = true) { self.autoDropAnalysis = autoDropAnalysis }
}

public struct RenderOptions: Sendable, Codable {
  public var conversationHasFunctionTools: Bool = false
  public init(conversationHasFunctionTools: Bool = false) { self.conversationHasFunctionTools = conversationHasFunctionTools }
}

public enum HarmonyEncodingName: String, Codable, Sendable {
  case harmonyGptOss = "HarmonyGptOss"
}

public enum SpecialTokenPolicy: Sendable {
  case disallowAll
  case allow(Set<String>)
  case allowAll
  case disallow(Set<String>)
  case disableChecks
}

public enum DecodeErrorMode: String, Sendable {
  case replace
  case strict
}

// MARK: - HarmonyEncoding wrapper

public final class HarmonyEncoding: @unchecked Sendable {
  private let inner: HarmonyEncodingFfi
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(name: HarmonyEncodingName = .harmonyGptOss) throws {
    self.inner = try HarmonyEncodingFfi(name: name.rawValue)
    self.encoder = HarmonyEncoding.makeEncoder()
    self.decoder = HarmonyEncoding.makeDecoder()
  }

  public var name: String { inner.name() }

  public var specialTokens: Set<String> {
    Set(inner.specialTokens())
  }

  public func renderConversationForCompletion(_ conversation: Conversation,
                                              nextTurnRole: Role,
                                              config: RenderConversationConfig = .init()) throws -> [UInt32] {
    let json = try encodeConversation(conversation)
    let cfg = RenderConversationConfigFfi(autoDropAnalysis: config.autoDropAnalysis)
    return try inner.renderConversationForCompletion(conversationJson: json,
                                                     nextTurnRole: nextTurnRole.rawValue,
                                                     config: cfg)
  }

  public func renderConversation(_ conversation: Conversation,
                                 config: RenderConversationConfig = .init()) throws -> [UInt32] {
    let json = try encodeConversation(conversation)
    let cfg = RenderConversationConfigFfi(autoDropAnalysis: config.autoDropAnalysis)
    return try inner.renderConversation(conversationJson: json, config: cfg)
  }

  public func renderConversationForTraining(_ conversation: Conversation,
                                            config: RenderConversationConfig = .init()) throws -> [UInt32] {
    let json = try encodeConversation(conversation)
    let cfg = RenderConversationConfigFfi(autoDropAnalysis: config.autoDropAnalysis)
    return try inner.renderConversationForTraining(conversationJson: json, config: cfg)
  }

  public func render(_ message: Message,
                     options: RenderOptions = .init()) throws -> [UInt32] {
    let json = try encodeMessage(message)
    let opts = RenderOptionsFfi(conversationHasFunctionTools: options.conversationHasFunctionTools)
    return try inner.render(messageJson: json, renderOptions: opts)
  }

  public func parseMessagesFromCompletionTokens(_ tokens: [UInt32],
                                                role: Role? = nil,
                                                strict: Bool = true) throws -> [Message] {
    let json = try inner.parseMessagesFromCompletionTokens(tokens: tokens,
                                                           role: role?.rawValue,
                                                           strict: strict)
    return try decoder.decode([Message].self, from: Data(json.utf8))
  }

  public func decodeUtf8(_ tokens: [UInt32]) throws -> String {
    try inner.decodeUtf8(tokens: tokens)
  }

  public func decode(_ tokens: [UInt32], errors: DecodeErrorMode = .replace) throws -> String {
    try inner.decodeBytes(tokens: tokens, errors: errors.rawValue)
  }

  public func encode(_ text: String, policy: SpecialTokenPolicy = .disallowAll) throws -> [UInt32] {
    let specials = specialTokens
    let allowed: Set<String>
    let disallowed: Set<String>

    switch policy {
    case .disallowAll:
      allowed = []
      disallowed = specials
    case .allow(let set):
      allowed = set
      disallowed = specials.subtracting(set)
    case .allowAll:
      allowed = specials
      disallowed = []
    case .disallow(let set):
      allowed = specials.subtracting(set)
      disallowed = set
    case .disableChecks:
      allowed = []
      disallowed = []
    }

    if !disallowed.isEmpty {
      let pattern = disallowed.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
      if let regex = try? NSRegularExpression(pattern: "(\(pattern))") {
        let range = NSRange(location: 0, length: text.utf16.count)
        if let match = regex.firstMatch(in: text, range: range) {
          let matched = (text as NSString).substring(with: match.range)
          throw HarmonyError.Msg("Encountered disallowed special token: \(matched)")
        }
      }
    }

    return try inner.encode(text: text, allowedSpecial: Array(allowed))
  }

  public func isSpecialToken(_ token: UInt32) -> Bool {
    inner.isSpecialToken(token: token)
  }

  public func stopTokens() throws -> [UInt32] {
    try inner.stopTokens()
  }

  public func stopTokensForAssistantActions() throws -> [UInt32] {
    try inner.stopTokensForAssistantActions()
  }

  public func newStreamParser(role: Role? = nil, strict: Bool = true) throws -> PicoHarmonyStreamParser {
    try inner.newStreamParser(role: role?.rawValue, strict: strict)
  }

  // MARK: Helpers
  private func encodeConversation(_ convo: Conversation) throws -> String {
    let data = try encoder.encode(convo)
    return String(decoding: data, as: UTF8.self)
  }

  private func encodeMessage(_ message: Message) throws -> String {
    let data = try encoder.encode(message)
    return String(decoding: data, as: UTF8.self)
  }

  private static func makeEncoder() -> JSONEncoder {
    let enc = JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    return enc
  }

  public static func makeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return dec
  }
}

// MARK: - Streamable parser (actor for safety)

public struct StreamDelta: Sendable {
  public var channel: String?
  public var delta: String?
  public var contentType: String?
  public var recipient: String?
}

public actor StreamableParser {
  private let inner: PicoHarmonyStreamParser
  private let decoder = HarmonyEncoding.makeDecoder()

  public init(encoding: HarmonyEncoding, role: Role? = nil, strict: Bool = true) throws {
    self.inner = try encoding.newStreamParser(role: role, strict: strict)
  }

  @discardableResult
  public func process(_ token: UInt32) throws -> StreamDelta {
    _ = try inner.process(tokenId: token)
    return try currentDelta()
  }

  @discardableResult
  public func processEOS() throws -> StreamDelta {
    try inner.processEos()
    return try currentDelta()
  }

  public func finish() throws -> ParsedAssistant {
    try inner.finish()
  }

  public func currentContent() throws -> String { try inner.currentContent() }
  public func currentRole() throws -> Role? { try inner.currentRole().map(Role.init(rawValue:)) ?? nil }
  public func currentChannel() throws -> String? { try inner.currentChannel() }
  public func currentRecipient() throws -> String? { try inner.currentRecipient() }
  public func currentContentType() throws -> String? { try inner.currentContentType() }
  public func lastContentDelta() throws -> String? { try inner.lastContentDelta() }

  public func messages() throws -> [Message] {
    let json = try inner.messagesJson()
    return try decoder.decode([Message].self, from: Data(json.utf8))
  }

  public func tokens() throws -> [UInt32] { try inner.tokens() }
  public func stateJSON() throws -> String { try inner.stateJson() }

  private func currentDelta() throws -> StreamDelta {
    StreamDelta(channel: try inner.currentChannel(),
                delta: try inner.lastContentDelta(),
                contentType: try inner.currentContentType(),
                recipient: try inner.currentRecipient())
  }
}

// MARK: - JSONValue helper for generic tool parameters

public enum JSONValue: Codable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let b = try? container.decode(Bool.self) { self = .bool(b) }
    else if let n = try? container.decode(Double.self) { self = .number(n) }
    else if let s = try? container.decode(String.self) { self = .string(s) }
    else if let arr = try? container.decode([JSONValue].self) { self = .array(arr) }
    else if let obj = try? container.decode([String: JSONValue].self) { self = .object(obj) }
    else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let s): try container.encode(s)
    case .number(let n): try container.encode(n)
    case .bool(let b): try container.encode(b)
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    case .null: try container.encodeNil()
    }
  }
}

import Foundation
import HarmonyUniFFI
import Darwin

// MARK: - Errors

public typealias HarmonyError = PicoHarmonyError

// MARK: - Core types (parity with Python __all__)

public enum Role: String, Codable, Sendable {
  case user, assistant, system, developer, tool
}

// MARK: - Common stringly-typed fields (Swifty wrappers)

/// A message "channel" such as "analysis", "commentary", or "final".
///
/// Modeled as an open set (not a closed enum) so callers can use custom channels
/// without losing type-safety at the API surface.
public struct Channel: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  public static let analysis: Channel = "analysis"
  public static let commentary: Channel = "commentary"
  public static let final: Channel = "final"
}

/// A message content type (e.g., "text"), modeled as an open set.
public struct ContentType: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  public static let text: ContentType = "text"
  public static let systemContent: ContentType = "system_content"
  public static let developerContent: ContentType = "developer_content"
}

/// A recipient identifier (often a tool / namespace) modeled as an open set.
public struct Recipient: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
}

public struct Author: Codable, Sendable {
  public var role: Role
  public var name: String?

  public init(role: Role, name: String? = nil) {
    self.role = role
    self.name = name
  }
}

public struct TextContent: Codable, Sendable, ExpressibleByStringLiteral {
  public var text: String
  public init(_ text: String) { self.text = text }

  public init(stringLiteral value: String) {
    self.text = value
  }
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

  /// Returns the canonical browser tool namespace configuration from Rust.
  public static func browser() throws -> ToolNamespaceConfig {
    let json = try getToolNamespaceConfigJson(tool: "browser")
    let decoder = HarmonyEncoding.makeDecoder()
    return try decoder.decode(ToolNamespaceConfig.self, from: Data(json.utf8))
  }

  /// Returns the canonical python tool namespace configuration from Rust.
  public static func python() throws -> ToolNamespaceConfig {
    let json = try getToolNamespaceConfigJson(tool: "python")
    let decoder = HarmonyEncoding.makeDecoder()
    return try decoder.decode(ToolNamespaceConfig.self, from: Data(json.utf8))
  }
}

public struct SystemContent: Codable, Sendable {
  public var modelIdentity: String?
  public var reasoningEffort: ReasoningEffort?
  public var conversationStartDate: String?
  public var knowledgeCutoff: String?
  public var channelConfig: ChannelConfig?
  public var tools: [String: ToolNamespaceConfig]?

  public init(modelIdentity: String? = nil,
              reasoningEffort: ReasoningEffort? = nil,
              conversationStartDate: String? = nil,
              knowledgeCutoff: String? = nil,
              channelConfig: ChannelConfig? = nil,
              tools: [String: ToolNamespaceConfig]? = nil) {
    self.modelIdentity = modelIdentity
    self.reasoningEffort = reasoningEffort
    self.conversationStartDate = conversationStartDate
    self.knowledgeCutoff = knowledgeCutoff
    self.channelConfig = channelConfig
    self.tools = tools
  }

  /// Returns the canonical default SystemContent from Rust.
  public static func makeDefault() throws -> SystemContent {
    let json = try getDefaultSystemContentJson()
    let decoder = HarmonyEncoding.makeDecoder()
    return try decoder.decode(SystemContent.self, from: Data(json.utf8))
  }

  /// Adds the browser tool namespace to this SystemContent.
  public mutating func withBrowserTool() throws {
    let browserConfig = try ToolNamespaceConfig.browser()
    if tools == nil { tools = [:] }
    tools?[browserConfig.name] = browserConfig
  }

  /// Adds the python tool namespace to this SystemContent.
  public mutating func withPythonTool() throws {
    let pythonConfig = try ToolNamespaceConfig.python()
    if tools == nil { tools = [:] }
    tools?[pythonConfig.name] = pythonConfig
  }

  /// Returns a copy with the browser tool added.
  public func addingBrowserTool() throws -> SystemContent {
    var copy = self
    try copy.withBrowserTool()
    return copy
  }

  /// Returns a copy with the python tool added.
  public func addingPythonTool() throws -> SystemContent {
    var copy = self
    try copy.withPythonTool()
    return copy
  }
}

public struct DeveloperContent: Codable, Sendable {
  public var instructions: String?
  public var tools: [String: ToolNamespaceConfig]?

  public init(instructions: String? = nil, tools: [String: ToolNamespaceConfig]? = nil) {
    self.instructions = instructions
    self.tools = tools
  }

  /// Adds function tools under the "functions" namespace.
  public mutating func withFunctionTools(_ functionTools: [ToolDescription]) {
    let config = ToolNamespaceConfig(name: "functions", description: nil, tools: functionTools)
    if tools == nil { tools = [:] }
    tools?[config.name] = config
  }

  /// Returns a copy with function tools added.
  public func addingFunctionTools(_ functionTools: [ToolDescription]) -> DeveloperContent {
    var copy = self
    copy.withFunctionTools(functionTools)
    return copy
  }
}

public enum Content: Codable, Sendable {
  case text(TextContent)
  case system(SystemContent)
  case developer(DeveloperContent)

  // MARK: - Convenience
  /// Allows `.text(myString)` when `myString` is a `String` (not just a string literal).
  public static func text(_ value: String) -> Content { .text(TextContent(value)) }

  private enum CodingKeys: String, CodingKey { case type, text }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case ContentType.text.rawValue:
      let text = try container.decode(String.self, forKey: .text)
      self = .text(TextContent(text))
    case ContentType.systemContent.rawValue:
      self = .system(try SystemContent(from: decoder))
    case ContentType.developerContent.rawValue:
      self = .developer(try DeveloperContent(from: decoder))
    default:
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                             debugDescription: "Unknown content type \(type)"))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let t):
      try container.encode(ContentType.text.rawValue, forKey: .type)
      try container.encode(t.text, forKey: .text)
    case .system(let sys):
      try container.encode(ContentType.systemContent.rawValue, forKey: .type)
      try sys.encode(to: encoder)
    case .developer(let dev):
      try container.encode(ContentType.developerContent.rawValue, forKey: .type)
      try dev.encode(to: encoder)
    }
  }
}

public struct Message: Codable, Sendable {
  public var author: Author
  public var content: [Content]
  public var channel: Channel?
  public var recipient: Recipient?
  public var contentType: ContentType?

  public init(author: Author,
              content: [Content],
              channel: Channel? = nil,
              recipient: Recipient? = nil,
              contentType: ContentType? = nil) {
    self.author = author
    self.content = content
    self.channel = channel
    self.recipient = recipient
    self.contentType = contentType
  }

  // MARK: - Factories
  public static func user(_ text: String,
                          name: String? = nil,
                          channel: Channel? = nil,
                          recipient: Recipient? = nil,
                          contentType: ContentType? = nil) -> Message {
    Message(author: Author(role: .user, name: name),
            content: [.text(text)],
            channel: channel,
            recipient: recipient,
            contentType: contentType)
  }

  public static func assistant(_ text: String,
                               name: String? = nil,
                               channel: Channel? = nil,
                               recipient: Recipient? = nil,
                               contentType: ContentType? = nil) -> Message {
    Message(author: Author(role: .assistant, name: name),
            content: [.text(text)],
            channel: channel,
            recipient: recipient,
            contentType: contentType)
  }

  public static func system(_ content: SystemContent,
                            channel: Channel? = nil) -> Message {
    Message(author: Author(role: .system),
            content: [.system(content)],
            channel: channel,
            contentType: .systemContent)
  }

  public static func developer(_ content: DeveloperContent,
                               channel: Channel? = nil) -> Message {
    Message(author: Author(role: .developer),
            content: [.developer(content)],
            channel: channel,
            contentType: .developerContent)
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
    if let ch = try container.decodeIfPresent(String.self, forKey: .channel) {
      self.channel = Channel(rawValue: ch)
    } else {
      self.channel = nil
    }

    if let r = try container.decodeIfPresent(String.self, forKey: .recipient) {
      self.recipient = Recipient(rawValue: r)
    } else {
      self.recipient = nil
    }

    if let ct = try container.decodeIfPresent(String.self, forKey: .contentType) {
      self.contentType = ContentType(rawValue: ct)
    } else {
      self.contentType = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(author.role, forKey: .role)
    try container.encodeIfPresent(author.name, forKey: .name)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(channel?.rawValue, forKey: .channel)
    try container.encodeIfPresent(recipient?.rawValue, forKey: .recipient)
    try container.encodeIfPresent(contentType?.rawValue, forKey: .contentType)
  }
}

public struct Conversation: Codable, Sendable {
  public var messages: [Message]
  public init(messages: [Message]) { self.messages = messages }
}

// MARK: - Render/parse options

public enum RenderPurpose: Sendable {
  case raw
  case completion(nextTurnRole: Role)
  case training
}

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

/// Value-type wrapper around the UniFFI encoding handle.
///
/// `HarmonyEncodingFfi` is generated by UniFFI and is `Sendable` (unchecked) on the Swift side.
/// We avoid storing `JSONEncoder` / `JSONDecoder` instances (which are reference types and not
/// guaranteed thread-safe) by creating them as-needed.
public struct HarmonyEncoding: Sendable {
  private static let bundledTokenizerBaseEnvVar = "TIKTOKEN_ENCODINGS_BASE"

  private let inner: HarmonyEncodingFfi
  private let cachedSpecialTokens: Set<String>

  public init(name: HarmonyEncodingName = .harmonyGptOss) throws {
    try Self.configureBundledTokenizerBaseDirectoryIfNeeded()
    self.inner = try HarmonyEncodingFfi(name: name.rawValue)
    self.cachedSpecialTokens = Set(inner.specialTokens())
  }

  public var name: String { inner.name() }

  public var specialTokens: Set<String> {
    cachedSpecialTokens
  }

  public func renderConversation(_ conversation: Conversation,
                                 purpose: RenderPurpose = .raw,
                                 config: RenderConversationConfig = .init()) throws -> [UInt32] {
    let json = try encodeConversation(conversation)
    let cfg = RenderConversationConfigFfi(autoDropAnalysis: config.autoDropAnalysis)

    switch purpose {
    case .raw:
      return try inner.renderConversation(conversationJson: json, config: cfg)
    case .training:
      return try inner.renderConversationForTraining(conversationJson: json, config: cfg)
    case .completion(let nextTurnRole):
      return try inner.renderConversationForCompletion(conversationJson: json,
                                                       nextTurnRole: nextTurnRole.rawValue,
                                                       config: cfg)
    }
  }

  // Backwards-compatible wrappers
  public func renderConversationForCompletion(_ conversation: Conversation,
                                              nextTurnRole: Role,
                                              config: RenderConversationConfig = .init()) throws -> [UInt32] {
    try renderConversation(conversation, purpose: .completion(nextTurnRole: nextTurnRole), config: config)
  }

  public func renderConversation(_ conversation: Conversation,
                                 config: RenderConversationConfig = .init()) throws -> [UInt32] {
    try renderConversation(conversation, purpose: .raw, config: config)
  }

  public func renderConversationForTraining(_ conversation: Conversation,
                                            config: RenderConversationConfig = .init()) throws -> [UInt32] {
    try renderConversation(conversation, purpose: .training, config: config)
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
    let dec = HarmonyEncoding.makeCompletionDecoder()
    return try dec.decode([Message].self, from: Data(json.utf8))
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
      // Deterministic iteration keeps errors reproducible across runs.
      for tok in disallowed.sorted() {
        if text.contains(tok) {
          throw HarmonyError.Msg("Encountered disallowed special token: \(tok)")
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
    let enc = HarmonyEncoding.makeEncoder()
    let data = try enc.encode(convo)
    return String(decoding: data, as: UTF8.self)
  }

  private func encodeMessage(_ message: Message) throws -> String {
    let enc = HarmonyEncoding.makeEncoder()
    let data = try enc.encode(message)
    return String(decoding: data, as: UTF8.self)
  }

  private static func makeEncoder() -> JSONEncoder {
    let enc = JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    // Using sortedKeys for deterministic output. Note that this may produce different
    // key ordering than Python/Rust for nested JSON objects like tool parameters.
    enc.outputFormatting = [.sortedKeys]
    return enc
  }

  public static func makeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return dec
  }

  private static func makeCompletionDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .useDefaultKeys
    return dec
  }

  private static func configureBundledTokenizerBaseDirectoryIfNeeded() throws {
    if getenv(bundledTokenizerBaseEnvVar) != nil {
      return
    }

    guard let tokenizerFileURL = bundledTokenizerFileURL() else {
      throw HarmonyError.Msg("Bundled tokenizer file o200k_base.tiktoken was not found in Harmony resources.")
    }

    let baseDirectory = tokenizerFileURL.deletingLastPathComponent().path
    guard setenv(bundledTokenizerBaseEnvVar, baseDirectory, 1) == 0 else {
      let err = String(cString: strerror(errno))
      throw HarmonyError.Msg("Failed setting \(bundledTokenizerBaseEnvVar) to \(baseDirectory): \(err)")
    }
  }

  private static func bundledTokenizerFileURL() -> URL? {
    if let url = Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken", subdirectory: "tiktoken") {
      return url
    }
    if let url = Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken", subdirectory: "Resources/tiktoken") {
      return url
    }
    return Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken")
  }
}

// MARK: - Streamable parser (actor for safety)

// Note: QoS Priority Inversion Warning
// -------------------------------------
// When calling StreamableParser from high-QoS Swift code, you may see:
//   "Thread running at User-initiated quality-of-service class waiting on a
//    lower QoS thread running at Default quality-of-service class"
//
// This occurs because the underlying Rust `PicoHarmonyStreamParser` uses
// `std::sync::Mutex`, which doesn't participate in Darwin's QoS priority
// inheritance. The warning is benign and does not cause crashes or App Store
// rejection. The OS mitigates via priority boosting.
//
// To avoid the warning, wrap parsing in a background task:
//   Task.detached(priority: .background) {
//       let delta = try await parser.process(token)
//   }
//
// Or use a dedicated dispatch queue with explicit QoS:
//   let parserQueue = DispatchQueue(label: "parser", qos: .utility)

public struct StreamDelta: Sendable {
  public let channel: Channel?
  public let delta: String?
  public let contentType: ContentType?
  public let recipient: Recipient?

  public init(channel: Channel? = nil,
              delta: String? = nil,
              contentType: ContentType? = nil,
              recipient: Recipient? = nil) {
    self.channel = channel
    self.delta = delta
    self.contentType = contentType
    self.recipient = recipient
  }
}

public actor StreamableParser {
  private let inner: PicoHarmonyStreamParser
  private let decoder = HarmonyEncoding.makeDecoder()
  private var lastSeenContentType: ContentType?
  private var lastSeenRecipient: Recipient?
  private var lastSeenChannel: Channel?

  public init(encoding: HarmonyEncoding, role: Role? = nil, strict: Bool = true) throws {
    self.inner = try encoding.newStreamParser(role: role, strict: strict)
  }

  @discardableResult
  public func process(_ token: UInt32) throws -> StreamDelta {
    let delta = try inner.process(tokenId: token)
    if let ct = delta.contentType { lastSeenContentType = ContentType(rawValue: ct) }
    if let r = delta.recipient { lastSeenRecipient = Recipient(rawValue: r) }
    if let ch = delta.channel { lastSeenChannel = Channel(rawValue: ch) }
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
  public func currentChannel() throws -> Channel? { try inner.currentChannel().map(Channel.init(rawValue:)) }
  public func currentRecipient() throws -> Recipient? { try inner.currentRecipient().map(Recipient.init(rawValue:)) }
  public func currentContentType() throws -> ContentType? { try inner.currentContentType().map(ContentType.init(rawValue:)) }
  public func lastContentDelta() throws -> String? { try inner.lastContentDelta() }

  public func messages() throws -> [Message] {
    let json = try inner.messagesJson()
    var msgs = try decoder.decode([Message].self, from: Data(json.utf8))
    if let idx = msgs.indices.last {
      if msgs[idx].contentType == nil {
        if let ct = try inner.currentContentType() ?? lastSeenContentType?.rawValue {
          msgs[idx].contentType = ContentType(rawValue: ct)
        }
      }
      if msgs[idx].recipient == nil {
        if let r = try inner.currentRecipient() ?? lastSeenRecipient?.rawValue {
          msgs[idx].recipient = Recipient(rawValue: r)
        }
      }
      if msgs[idx].channel == nil {
        if let ch = try inner.currentChannel() ?? lastSeenChannel?.rawValue {
          msgs[idx].channel = Channel(rawValue: ch)
        }
      }
    }
    return msgs
  }

  public func tokens() throws -> [UInt32] { try inner.tokens() }
  public func stateJSON() throws -> String { try inner.stateJson() }

  private func currentDelta() throws -> StreamDelta {
    StreamDelta(channel: try inner.currentChannel().map(Channel.init(rawValue:)),
                delta: try inner.lastContentDelta(),
                contentType: try inner.currentContentType().map(ContentType.init(rawValue:)),
                recipient: try inner.currentRecipient().map(Recipient.init(rawValue:)))
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

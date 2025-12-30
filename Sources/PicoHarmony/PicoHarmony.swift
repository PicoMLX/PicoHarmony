// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import HarmonyUniFFI

public struct HarmonyDecoder {
  public init() {}

  public func decodeFinal(tokenIDs: [UInt32]) throws -> String? {
    let enc = try HarmonyGptOss()
    return try enc.parseCompletionTokens(tokenIds: tokenIDs).finalText
  }
}

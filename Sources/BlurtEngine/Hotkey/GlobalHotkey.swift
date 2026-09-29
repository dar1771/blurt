public struct GlobalHotkey: Sendable, Equatable {
  public let keyCode: Int
  public let requiresOption: Bool
  public let requiresCommand: Bool

  public init(keyCode: Int, requiresOption: Bool = true, requiresCommand: Bool = true) {
    self.keyCode = keyCode
    self.requiresOption = requiresOption
    self.requiresCommand = requiresCommand
  }

  public func matches(keyCode: Int, optionDown: Bool, commandDown: Bool) -> Bool {
    self.keyCode == keyCode && (!requiresOption || optionDown) && (!requiresCommand || commandDown)
  }

  public static let insertLast = GlobalHotkey(keyCode: 9)  // V
  public static let openHistory = GlobalHotkey(keyCode: 4)  // H
}

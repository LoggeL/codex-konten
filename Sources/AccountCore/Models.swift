import Foundation
public struct AccountUsage: Codable, Sendable {
    public var fiveHourRemaining: Double?
    public var weeklyRemaining: Double?
    public var fiveHourReset: Date?
    public var weeklyReset: Date?
    public var fetchedAt: Date
    public init(fiveHourRemaining: Double?, weeklyRemaining: Double?, fiveHourReset: Date?, weeklyReset: Date?, fetchedAt: Date) { self.fiveHourRemaining = fiveHourRemaining; self.weeklyRemaining = weeklyRemaining; self.fiveHourReset = fiveHourReset; self.weeklyReset = weeklyReset; self.fetchedAt = fetchedAt }
}
public struct SavedAccountView: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String
    public let isActive: Bool
    public let usage: AccountUsage?
    public let error: String?
    public init(id: String, displayName: String, email: String, isActive: Bool, usage: AccountUsage?, error: String?) { self.id = id; self.displayName = displayName; self.email = email; self.isActive = isActive; self.usage = usage; self.error = error }
}
public struct AccountSnapshot: Sendable {
    public let accounts: [SavedAccountView]
    public let cliPath: String?
    public let currentAccountLabel: String?
    public let notice: String?
    public init(accounts: [SavedAccountView], cliPath: String?, currentAccountLabel: String?, notice: String?) { self.accounts = accounts; self.cliPath = cliPath; self.currentAccountLabel = currentAccountLabel; self.notice = notice }
}
public typealias AccountProgress = @Sendable (String) async -> Void
public enum AccountError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

import Foundation

struct QuotaWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    func merging(_ update: QuotaWindow) -> QuotaWindow {
        QuotaWindow(
            usedPercent: update.usedPercent,
            windowDurationMins: update.windowDurationMins ?? windowDurationMins,
            resetsAt: update.resetsAt ?? resetsAt
        )
    }
}

enum QuotaWindowPresentation {
    static func durationLabel(for window: QuotaWindow) -> String {
        guard let minutes = window.windowDurationMins, minutes > 0 else { return "额度窗口" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440) 天窗口" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时窗口" }
        return "\(minutes) 分钟窗口"
    }

    static func resetLabel(for window: QuotaWindow, now: Date) -> String {
        guard let timestamp = window.resetsAt else { return "重置时间未知" }
        let remaining = Int(Date(timeIntervalSince1970: timestamp).timeIntervalSince(now))
        guard remaining > 0 else { return "即将重置" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时后重置" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分后重置" }
        return "\(max(1, minutes)) 分钟后重置"
    }
}

struct Credits: Codable, Equatable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct LimitBucket: Codable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let credits: Credits?
    let spendControlReached: Bool?
    let planType: String?
    let rateLimitReachedType: String?

    var displayName: String {
        if let limitName, !limitName.isEmpty { return limitName }
        if let limitId, !limitId.isEmpty { return limitId }
        return "Codex"
    }

    func merging(_ update: LimitBucket) -> LimitBucket {
        LimitBucket(
            limitId: update.limitId ?? limitId,
            limitName: update.limitName ?? limitName,
            primary: mergeWindow(primary, update.primary),
            secondary: mergeWindow(secondary, update.secondary),
            credits: update.credits ?? credits,
            spendControlReached: update.spendControlReached ?? spendControlReached,
            planType: update.planType ?? planType,
            rateLimitReachedType: update.rateLimitReachedType ?? rateLimitReachedType
        )
    }

    private func mergeWindow(_ current: QuotaWindow?, _ update: QuotaWindow?) -> QuotaWindow? {
        switch (current, update) {
        case let (current?, update?): current.merging(update)
        case let (_, update?): update
        case let (current?, nil): current
        case (nil, nil): nil
        }
    }
}

struct RateLimitResetCredits: Codable, Equatable, Sendable {
    let availableCount: Int?
}

struct RateLimitsResult: Codable, Equatable, Sendable {
    let rateLimits: LimitBucket?
    let rateLimitsByLimitId: [String: LimitBucket]?
    let rateLimitResetCredits: RateLimitResetCredits?
}

struct RateLimitSnapshot: Equatable, Sendable {
    struct WindowEntry: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case primary
            case secondary

            var localizedName: String {
                switch self {
                case .primary: "主额度"
                case .secondary: "次额度"
                }
            }
        }

        let bucketId: String
        let bucketName: String
        let kind: Kind
        let window: QuotaWindow
        let planType: String?

        var id: String { "\(bucketId)-\(kind.rawValue)" }

        var durationLabel: String {
            QuotaWindowPresentation.durationLabel(for: window)
        }
    }

    var buckets: [String: LimitBucket]
    var resetCreditCount: Int?
    var receivedAt: Date

    init(result: RateLimitsResult, receivedAt: Date = Date()) {
        if let byId = result.rateLimitsByLimitId, !byId.isEmpty {
            buckets = byId
        } else if let bucket = result.rateLimits {
            let key = bucket.limitId ?? "codex"
            buckets = [key: bucket]
        } else {
            buckets = [:]
        }
        resetCreditCount = result.rateLimitResetCredits?.availableCount
        self.receivedAt = receivedAt
    }

    var windows: [WindowEntry] {
        buckets
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .flatMap { key, bucket -> [WindowEntry] in
                var entries: [WindowEntry] = []
                if let primary = bucket.primary {
                    entries.append(.init(
                        bucketId: key,
                        bucketName: bucket.displayName,
                        kind: .primary,
                        window: primary,
                        planType: bucket.planType
                    ))
                }
                if let secondary = bucket.secondary {
                    entries.append(.init(
                        bucketId: key,
                        bucketName: bucket.displayName,
                        kind: .secondary,
                        window: secondary,
                        planType: bucket.planType
                    ))
                }
                return entries
            }
    }

    var displayWindows: [WindowEntry] {
        windows.sorted { lhs, rhs in
            let lhsDuration = lhs.window.windowDurationMins ?? Int.max
            let rhsDuration = rhs.window.windowDurationMins ?? Int.max
            if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
            if lhs.bucketName != rhs.bucketName {
                return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
            }
            if lhs.bucketId != rhs.bucketId { return lhs.bucketId < rhs.bucketId }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    var menuTitle: String? {
        guard !displayWindows.isEmpty else { return nil }
        return displayWindows
            .map { "\(Int($0.window.remainingPercent.rounded()))%" }
            .joined(separator: " | ")
    }

    var menuAccessibilityTitle: String? {
        guard !displayWindows.isEmpty else { return nil }
        return displayWindows
            .map { "\($0.durationLabel) \(Int($0.window.remainingPercent.rounded()))%" }
            .joined(separator: "，")
    }

    var mainRemainingPercent: Double? {
        windows.map(\.window.remainingPercent).min()
    }

    mutating func merge(bucket: LimitBucket, receivedAt: Date = Date()) {
        let key = bucket.limitId ?? "codex"
        if let current = buckets[key] {
            buckets[key] = current.merging(bucket)
        } else {
            buckets[key] = bucket
        }
        self.receivedAt = receivedAt
    }
}

enum RateLimitDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static func decodeResult(from value: Any) throws -> RateLimitsResult {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decoder.decode(RateLimitsResult.self, from: data)
    }

    static func decodeBucket(from value: Any) throws -> LimitBucket {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decoder.decode(LimitBucket.self, from: data)
    }
}

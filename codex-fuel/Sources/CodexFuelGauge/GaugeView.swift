import AppKit
import SwiftUI

enum SystemMetricPresentation {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "--" }
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            let megabytes = value / 1_048_576
            return megabytes.rounded() == megabytes
                ? "\(Int(megabytes)) MB"
                : String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), megabytes)
        }
        if value >= 1_024 {
            return "\(Int((value / 1_024).rounded())) KB"
        }
        return "\(bytes) B"
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite else { return "--" }
        let value = max(0, bytesPerSecond)
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB/s", locale: Locale(identifier: "en_US_POSIX"), value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return String(format: "%.1f MB/s", locale: Locale(identifier: "en_US_POSIX"), value / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.1f KB/s", locale: Locale(identifier: "en_US_POSIX"), value / 1_024)
        }
        return "\(Int(value.rounded())) B/s"
    }
}

struct GaugeRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                quotaCard
                systemOverview
                topApplications
            }
            .padding(16)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .padding(8)
        .preferredColorScheme(nil)
    }

    private var quotaCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CODEX FUEL")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("额度仪表")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                }
                Spacer()
                if let plan = model.snapshot?.buckets.values.compactMap(\.planType).first {
                    Text(plan.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }

            if let windows = model.snapshot?.displayWindows, windows.count >= 2 {
                QuotaWindowOverview(entries: windows)
            } else {
                GaugeDial(remainingPercent: model.remainingPercent)
                    .frame(height: 136)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.connectionState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            if !model.codexRunning, model.snapshot == nil {
                Text("启动 Codex 后自动读取额度")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var systemOverview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("本机状态")
                    .font(.headline)
                Spacer()
                Text(model.panelVisible ? "每秒更新" : "每 5 秒更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 7) {
                SystemMetricCard(kind: .cpu, snapshot: model.systemSnapshot)
                SystemMetricCard(kind: .memory, snapshot: model.systemSnapshot)
                SystemMetricCard(kind: .network, snapshot: model.systemSnapshot)
            }
        }
    }

    private var topApplications: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("应用 Top 5")
                    .font(.headline)
                Spacer()
                if let systemSnapshot = model.systemSnapshot {
                    Text(systemSnapshot.networkState.message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Picker("排行指标", selection: $model.selectedSystemMetric) {
                Text("CPU").tag(SystemMetricKind.cpu)
                Text("内存").tag(SystemMetricKind.memory)
                Text("网络").tag(SystemMetricKind.network)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 0) {
                if model.selectedTopApplications.isEmpty {
                    Text("采样中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    ForEach(Array(model.selectedTopApplications.enumerated()), id: \.element.id) { index, metric in
                        SystemApplicationRow(
                            rank: index + 1,
                            metric: metric,
                            kind: model.selectedSystemMetric
                        )
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: gaugeColor(for: model.remainingPercent)
        case .connecting: .blue
        case .waitingForCodex, .stale, .unavailable: .secondary
        }
    }

}

struct QuotaWindowOverview: View {
    let entries: [RateLimitSnapshot.WindowEntry]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    QuotaWindowCard(entry: entry, now: context.date)
                }
            }
        }
        .frame(height: 136)
    }
}

struct QuotaWindowCard: View {
    let entry: RateLimitSnapshot.WindowEntry
    let now: Date

    private var remainingText: String {
        "\(Int(entry.window.remainingPercent.rounded()))%"
    }

    private var resetText: String {
        QuotaWindowPresentation.resetLabel(for: entry.window, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.durationLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(remainingText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(gaugeColor(for: entry.window.remainingPercent))

            ProgressView(value: entry.window.remainingPercent, total: 100)
                .tint(gaugeColor(for: entry.window.remainingPercent))

            Text(entry.bucketName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.durationLabel) \(entry.bucketName)")
        .accessibilityValue("剩余 \(remainingText)，\(resetText)")
    }
}

enum SystemMetricCardLayout {
    static let cardHeight: CGFloat = 84
    static let cornerRadius: CGFloat = 13
    static let padding: CGFloat = 10
}

struct SystemMetricCard: View {
    let kind: SystemMetricKind
    let snapshot: SystemMetricsSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if kind == .network {
                VStack(alignment: .leading, spacing: 2) {
                    Text("↓ \(SystemMetricPresentation.rate(snapshot?.bytesInPerSecond))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("↑ \(SystemMetricPresentation.rate(snapshot?.bytesOutPerSecond))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text(primaryValue)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                ProgressView(value: progressValue, total: 100)
                    .tint(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SystemMetricCardLayout.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: SystemMetricCardLayout.cardHeight, alignment: .topLeading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: SystemMetricCardLayout.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(primaryValue)
    }

    private var title: String {
        switch kind {
        case .cpu: "CPU"
        case .memory: "内存"
        case .network: "网络"
        }
    }

    private var iconName: String {
        switch kind {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        }
    }

    private var color: Color {
        switch kind {
        case .cpu: .blue
        case .memory: .purple
        case .network: .orange
        }
    }

    private var primaryValue: String {
        switch kind {
        case .cpu: return SystemMetricPresentation.percent(snapshot?.cpuPercent)
        case .memory:
            guard let snapshot, snapshot.memoryTotalBytes > 0, let used = snapshot.memoryUsedBytes else { return "--" }
            return SystemMetricPresentation.percent(Double(used) / Double(snapshot.memoryTotalBytes) * 100)
        case .network:
            return "下载 \(SystemMetricPresentation.rate(snapshot?.bytesInPerSecond))，上传 \(SystemMetricPresentation.rate(snapshot?.bytesOutPerSecond))"
        }
    }

    private var progressValue: Double {
        switch kind {
        case .cpu: return snapshot?.cpuPercent ?? 0
        case .memory:
            guard let snapshot, snapshot.memoryTotalBytes > 0, let used = snapshot.memoryUsedBytes else { return 0 }
            return min(100, Double(used) / Double(snapshot.memoryTotalBytes) * 100)
        case .network: return 0
        }
    }
}

struct SystemApplicationRow: View {
    let rank: Int
    let metric: SystemApplicationMetric
    let kind: SystemMetricKind

    var body: some View {
        HStack(spacing: 9) {
            Text("\(rank)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            ApplicationIconView(identity: metric.application)

            Text(metric.application.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            value
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 54)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(rank)名 \(metric.application.displayName)")
    }

    private var value: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch kind {
            case .cpu:
                Text(SystemMetricPresentation.percent(metric.cpuPercent))
            case .memory:
                Text(SystemMetricPresentation.memory(metric.memoryBytes))
            case .network:
                Text("↓ \(SystemMetricPresentation.rate(metric.bytesInPerSecond))")
                Text("↑ \(SystemMetricPresentation.rate(metric.bytesOutPerSecond))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.primary)
    }
}

private enum ApplicationIconCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ApplicationIconView: View {
    let identity: ApplicationIdentity

    private var icon: NSImage? {
        guard let bundleURL = identity.bundleURL else { return nil }
        return ApplicationIconCache.image(for: bundleURL)
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
        }
    }
}

struct GaugeDial: View {
    let remainingPercent: Double?

    private var fraction: Double {
        min(1, max(0, (remainingPercent ?? 0) / 100))
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.9)
                let radius = min(size.width * 0.39, size.height * 0.78)
                let start = 200.0
                let end = 340.0

                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                context.stroke(track, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 16, lineCap: .round))

                if remainingPercent != nil {
                    var progress = Path()
                    progress.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + ((end - start) * fraction)), clockwise: false)
                    context.stroke(progress, with: .color(gaugeColor(for: remainingPercent)), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                }

                for tick in 0...10 {
                    let angle = start + (end - start) * Double(tick) / 10
                    let radians = angle * .pi / 180
                    let outer = CGPoint(x: center.x + cos(radians) * (radius + 15), y: center.y + sin(radians) * (radius + 15))
                    let inner = CGPoint(x: center.x + cos(radians) * (radius + (tick.isMultiple(of: 5) ? 3 : 7)), y: center.y + sin(radians) * (radius + (tick.isMultiple(of: 5) ? 3 : 7)))
                    var tickPath = Path()
                    tickPath.move(to: inner)
                    tickPath.addLine(to: outer)
                    context.stroke(tickPath, with: .color(.secondary.opacity(0.65)), lineWidth: tick.isMultiple(of: 5) ? 2 : 1)
                }

                let needleAngle = (start + ((end - start) * fraction)) * .pi / 180
                let needleEnd = CGPoint(x: center.x + cos(needleAngle) * (radius - 16), y: center.y + sin(needleAngle) * (radius - 16))
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: needleEnd)
                context.stroke(needle, with: .color(remainingPercent == nil ? .secondary : gaugeColor(for: remainingPercent)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(.primary))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(Color(nsColor: .windowBackgroundColor)))
            }

            VStack(spacing: 0) {
                Text(valueText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remainingPercent == nil ? .secondary : gaugeColor(for: remainingPercent))
                Text("REMAINING")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
            }
            .offset(y: -4)

            HStack {
                Text("E")
                Spacer()
                Text("F")
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 19)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 剩余用量")
        .accessibilityValue(valueText)
    }

    private var valueText: String {
        guard let remainingPercent else { return "--" }
        return "\(Int(remainingPercent.rounded()))%"
    }
}

func gaugeColor(for remainingPercent: Double?) -> Color {
    guard let remainingPercent else { return .secondary }
    if remainingPercent <= 10 { return .red }
    if remainingPercent <= 30 { return .orange }
    return .green
}

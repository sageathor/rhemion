import Foundation

public protocol MetricsSink: Sendable {
    func write(_ line: String)
}

public struct StderrSink: MetricsSink {
    public init() {}
    public func write(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
}

public struct Metrics: Sendable {
    private let enabled: Bool
    private let now: @Sendable () -> Double
    private let sink: MetricsSink

    public init(enabled: Bool, now: @escaping @Sendable () -> Double, sink: MetricsSink) {
        self.enabled = enabled; self.now = now; self.sink = sink
    }

    public func record(_ event: String, session: String?) {
        guard enabled else { return }
        sink.write("[timing] \(event) session=\(session ?? "-") t=\(now())")
    }

    public static func fromEnvironment(sink: MetricsSink = StderrSink()) -> Metrics {
        let on = ProcessInfo.processInfo.environment["RHEMION_TIMING"] == "1"
        let clock = { @Sendable in Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
        return Metrics(enabled: on, now: clock, sink: sink)
    }
}

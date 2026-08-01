import Darwin
import Foundation
import XCTest

@testable import Markdown

final class SearchBenchmarkTests: XCTestCase {
    func testDeterministicTenAndFiftyThousandNoteThresholds() async throws {
#if MARKDOWN_SEARCH_BENCHMARK_FULL
        let iterations = 12
#else
        // The mandatory suite always runs a quick, real 10k/50k gate. The
        // standalone --full profile expands the distribution to 12 samples.
        let iterations = 3
#endif
        try await benchmark(noteCount: 10_000, iterations: iterations, p95LimitMilliseconds: 500)
        try await benchmark(noteCount: 50_000, iterations: iterations, p95LimitMilliseconds: 2_000)
    }

    private func benchmark(
        noteCount: Int,
        iterations: Int,
        p95LimitMilliseconds: Double
    ) async throws {
        let baselinePeakBytes = Self.processPeakResidentBytes()
        let entries = Self.makeEntries(count: noteCount)

        // Warm caches before collecting a distribution.
        _ = Workspace.search(entries, query: "benchmark-target")

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for iteration in 0..<iterations {
            let query = iteration.isMultiple(of: 2) ? "benchmark-target" : "shard-73"
            let started = DispatchTime.now().uptimeNanoseconds
            let results = Workspace.search(entries, query: query)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            XCTAssertFalse(results.isEmpty)
            samples.append(Double(elapsed) / 1_000_000)
        }

        let sorted = samples.sorted()
        let p50 = Self.percentile(0.50, in: sorted)
        let p95 = Self.percentile(0.95, in: sorted)

        let cancellationWorker = Task.detached(priority: .userInitiated) {
            Workspace.search(entries, query: "definitely-absent-cancellation-query")
        }
        try await Task.sleep(for: .milliseconds(1))
        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        cancellationWorker.cancel()
        _ = await cancellationWorker.value
        let cancellationMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStarted
        ) / 1_000_000

        let peakBytes = Self.processPeakResidentBytes()
        let peakDeltaBytes = peakBytes >= baselinePeakBytes ? peakBytes - baselinePeakBytes : 0
        let peakMegabytes = Double(peakBytes) / 1_048_576
        let peakDeltaMegabytes = Double(peakDeltaBytes) / 1_048_576

        print(
            String(
                format: "SEARCH_BENCHMARK notes=%d iterations=%d p50_ms=%.2f p95_ms=%.2f peak_rss_mb=%.1f peak_delta_mb=%.1f cancellation_ms=%.2f",
                noteCount,
                iterations,
                p50,
                p95,
                peakMegabytes,
                peakDeltaMegabytes,
                cancellationMilliseconds
            )
        )

        XCTAssertLessThanOrEqual(
            p95,
            p95LimitMilliseconds,
            "\(noteCount)-note p95 exceeded the maintained threshold"
        )
        XCTAssertLessThanOrEqual(
            peakDeltaBytes,
            1_024 * 1_024 * 1_024,
            "\(noteCount)-note search retained more than 1 GiB above the test-host peak baseline"
        )
        XCTAssertLessThanOrEqual(
            cancellationMilliseconds,
            200,
            "Cancellation should be observed within 200 ms"
        )
    }

    private static func makeEntries(count: Int) -> [NoteSearchEntry] {
        let filler = String(repeating: "alpha beta gamma delta interface craft ", count: 6)
        return (0..<count).map { index in
            let title = String(format: "Note %05d", index)
            let body = "# \(title)\n\n\(filler)shard-\(index % 101) "
                + (index.isMultiple(of: 997) ? "benchmark-target" : "ordinary-content")
            let url = URL(fileURLWithPath: "/benchmark/\(title).md")
            return NoteSearchEntry(
                id: url,
                url: url,
                title: title,
                relativePath: "benchmark/\(title).md",
                body: body,
                foldedTitle: Workspace.foldedForSearch(title),
                foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(title).md")
            )
        }
    }

    private static func percentile(_ percentile: Double, in sortedSamples: [Double]) -> Double {
        guard !sortedSamples.isEmpty else { return 0 }
        let index = max(0, min(sortedSamples.count - 1, Int(ceil(percentile * Double(sortedSamples.count))) - 1))
        return sortedSamples[index]
    }

    private static func processPeakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }
}

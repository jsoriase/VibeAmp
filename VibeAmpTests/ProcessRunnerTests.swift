import XCTest
@testable import VibeAmp

/// Regression tests for ProcessRunner pipe discipline.
/// yt-dlp --dump-json emits hundreds of KB; reading pipes only after exit
/// deadlocks past the 64 KB buffer. These use large local output instead
/// of the network so they stay fast and hermetic.
final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputLargerThanPipeBuffer() async throws {
        // ~200 KB of stdout — must be drained while the child runs.
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "30000"]
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.stdout.hasSuffix("30000\n"), "tail truncated: \(result.stdout.suffix(20))")
        XCTAssertTrue(result.stdout.hasPrefix("1\n2\n3\n"))
    }

    func testNonZeroExitThrowsWithStderr() async {
        let runner = ProcessRunner()
        do {
            _ = try await runner.runChecked(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["false-does-not-exist-xyz"]
            )
            XCTFail("expected throw")
        } catch {
            // env prints "...: No such file or directory" to stderr; either way it throws.
            XCTAssertNotNil(error as? ProcessRunner.ProcessError)
        }
    }

    func testMissingBinaryThrowsLaunchFailed() async {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/vibeamp-probe"),
                arguments: []
            )
            XCTFail("expected throw")
        } catch let error as ProcessRunner.ProcessError {
            if case .launchFailed = error { /* expected */ }
            else { XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

@testable import AppBundle
import Common
import XCTest

@MainActor
final class DebugWindowsCommandTest: XCTestCase {
    override func tearDown() async throws {
        resetNativeSpaceStateForTests()
    }

    func testParse() {
        testParseCommandSucc("debug-windows", DebugWindowsCmdArgs(rawArgs: []))
        testParseCommandSucc(
            "debug-windows --native-spaces",
            DebugWindowsCmdArgs(rawArgs: []).copy(\.nativeSpaces, true),
        )
        testParseCommandSucc(
            "debug-windows --window-id 42",
            DebugWindowsCmdArgs(rawArgs: []).copy(\.windowId, 42),
        )
        assertEquals(
            parseCommand("debug-windows --native-spaces --window-id 42").errorOrNil,
            "ERROR: Conflicting options: --native-spaces, --window-id",
        )
    }

    func testNativeSpacesOutput() async throws {
        nativeSpaceKeyForTests = NativeSpaceKey(raw: "test-debug-command-native-space")
        currentNativeSpaceIdsForTests = [42]
        currentNativeSpaceWindowIdsForTests = [7]
        nativeSpaceIdsForWindowIdForTests[7] = [42]

        let result = try await parseCommand("debug-windows --native-spaces").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let stdout = result.stdout.joined(separator: "\n")

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        XCTAssertTrue(stdout.contains("\"current-native-space-key\" : \"test-debug-command-native-space\""), stdout)
        XCTAssertTrue(stdout.contains("\"current-native-space-is-user\" : true"), stdout)
        XCTAssertTrue(stdout.contains("\"space-kind\" : \"unknown\""), stdout)
        XCTAssertTrue(stdout.contains("\"space-type\" : null"), stdout)
        XCTAssertTrue(stdout.contains("\"7\" : ["), stdout)
        XCTAssertTrue(stdout.contains("debug-windows' command is not stable API"), stdout)
    }
}

@testable import AppBundle
import Common
import XCTest

@MainActor
final class FlattenWorkspaceTreeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSimple() async throws {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
            TestWindow.new(id: 3, parent: $0) // floating
        }
        assertEquals(workspace.focusWorkspace(), true)

        try await FlattenWorkspaceTreeCommand(args: FlattenWorkspaceTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.layoutDescription, .workspace([.h_tiles([.window(1), .window(2)]), .window(3)]))
    }

    func testForceFloatingKeepsFlattenedWindowsFloating() async throws {
        config.experimentalForceFloatingWindows = true
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }
        assertEquals(workspace.focusWorkspace(), true)

        try await FlattenWorkspaceTreeCommand(args: FlattenWorkspaceTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)

        assertEquals(workspace.children.filterIsInstance(of: Window.self).map(\.windowId).toSet(), [1, 2])
        assertEquals(workspace.rootTilingContainer.children.count, 0)
    }
}

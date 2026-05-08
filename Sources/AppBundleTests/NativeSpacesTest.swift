@testable import AppBundle
import Common
import HotKey
import XCTest

@MainActor
final class NativeSpacesTest: XCTestCase {
    override func setUp() async throws {
        resetNativeSpaceStateForTests()
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        resetNativeSpaceStateForTests()
        setUpWorkspacesForTests()
    }

    func testWorkspacesAreNativeSpaceScoped() {
        let spaceA = NativeSpaceKey(raw: "test-workspaces-a")
        let spaceB = NativeSpaceKey(raw: "test-workspaces-b")

        setUpWorkspacesForTests(nativeSpaceKey: spaceA)
        check(Workspace.get(byName: "a").focusWorkspace())
        assertEquals(userWorkspaceNames(), ["a"])

        setUpWorkspacesForTests(nativeSpaceKey: spaceB)
        check(Workspace.get(byName: "b").focusWorkspace())
        assertEquals(userWorkspaceNames(), ["b"])

        nativeSpaceKeyForTests = spaceA
        assertEquals(userWorkspaceNames(), ["a"])
        assertEquals(focus.workspace.name, "a")

        nativeSpaceKeyForTests = spaceB
        assertEquals(userWorkspaceNames(), ["b"])
        assertEquals(focus.workspace.name, "b")
    }

    func testBackAndForthHistoryIsNativeSpaceScoped() {
        let spaceA = NativeSpaceKey(raw: "test-focus-a")
        let spaceB = NativeSpaceKey(raw: "test-focus-b")

        setUpWorkspacesForTests(nativeSpaceKey: spaceA)
        check(Workspace.get(byName: "a1").focusWorkspace())
        checkOnFocusChangedCallbacks()
        check(Workspace.get(byName: "a2").focusWorkspace())
        checkOnFocusChangedCallbacks()
        assertEquals(prevFocusedWorkspace?.name, "a1")

        setUpWorkspacesForTests(nativeSpaceKey: spaceB)
        check(Workspace.get(byName: "b1").focusWorkspace())
        checkOnFocusChangedCallbacks()
        check(Workspace.get(byName: "b2").focusWorkspace())
        checkOnFocusChangedCallbacks()
        assertEquals(prevFocusedWorkspace?.name, "b1")

        nativeSpaceKeyForTests = spaceA
        assertEquals(focus.workspace.name, "a2")
        assertEquals(prevFocusedWorkspace?.name, "a1")

        nativeSpaceKeyForTests = spaceB
        assertEquals(focus.workspace.name, "b2")
        assertEquals(prevFocusedWorkspace?.name, "b1")
    }

    func testWindowNativeSpacesFormatUsesNativeSpaceMembership() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-spaces"))
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        nativeSpaceIdsForWindowIdForTests[1] = [200, 100]

        let result = try await parseCommand("list-windows --all --format '%{window-native-spaces}'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.stdout, ["100,200"])
    }

    func testWindowNativeSpacesFormatIsEmptyWhenDisabled() async throws {
        setUpWorkspacesForTests()
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        nativeSpaceIdsForWindowIdForTests[1] = [100]

        let result = try await parseCommand("list-windows --all --format '%{window-native-spaces}'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.stdout, [""])
    }

    func testWindowNativeSpacesFormatReportsUnavailableWhenEnabledButUnreadable() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-spaces-unavailable"))
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)

        let result = try await parseCommand("list-windows --all --format '%{window-native-spaces}'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.stdout, ["unavailable"])
    }

    func testNativeSpaceFormatUsesWorkspaceNamespace() async throws {
        let nativeSpaceKey = NativeSpaceKey(raw: "test-native-space-format")
        setUpWorkspacesForTests(nativeSpaceKey: nativeSpaceKey)
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)

        let workspaces = try await parseCommand("list-workspaces --all --format '%{workspace} %{native-space}'").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let windows = try await parseCommand("list-windows --all --format '%{workspace} %{native-space}'").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(workspaces.stdout.filter { $0.hasPrefix("a ") }, ["a \(nativeSpaceKey.raw)"])
        assertEquals(windows.stdout, ["a \(nativeSpaceKey.raw)"])
    }

    func testWindowLookupIsNativeSpaceScoped() {
        let spaceA = NativeSpaceKey(raw: "test-window-lookup-a")
        let spaceB = NativeSpaceKey(raw: "test-window-lookup-b")

        setUpWorkspacesForTests(nativeSpaceKey: spaceA)
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        XCTAssertNotNil(Window.get(byId: 1))

        nativeSpaceKeyForTests = spaceB
        XCTAssertNil(Window.get(byId: 1))

        nativeSpaceKeyForTests = spaceA
        XCTAssertNotNil(Window.get(byId: 1))
    }

    func testWindowLookupScopesGlobalContainersByNativeSpaceMembership() {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-global-window-lookup"))
        currentNativeSpaceIdsForTests = [100]
        TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        TestWindow.new(id: 2, parent: macosPopupWindowsContainer)

        nativeSpaceIdsForWindowIdForTests[1] = [200]
        nativeSpaceIdsForWindowIdForTests[2] = [200]
        XCTAssertNil(Window.get(byId: 1))
        XCTAssertNil(Window.get(byId: 2))

        nativeSpaceIdsForWindowIdForTests[1] = [100]
        nativeSpaceIdsForWindowIdForTests[2] = [100, 200]
        XCTAssertNotNil(Window.get(byId: 1))
        XCTAssertNotNil(Window.get(byId: 2))
    }

    func testRefreshLivenessChecksOnlyCurrentNativeSpaceWindows() {
        let spaceA = NativeSpaceKey(raw: "test-liveness-a")
        let spaceB = NativeSpaceKey(raw: "test-liveness-b")

        setUpWorkspacesForTests(nativeSpaceKey: spaceA)
        let oldWindow = TestWindow.new(id: 1, parent: Workspace.get(byName: "old").rootTilingContainer)
        let oldPopup = TestWindow.new(id: 2, parent: macosPopupWindowsContainer)

        setUpWorkspacesForTests(nativeSpaceKey: spaceB)
        let currentWindow = TestWindow.new(id: 3, parent: Workspace.get(byName: "current").rootTilingContainer)
        let currentPopup = TestWindow.new(id: 4, parent: macosPopupWindowsContainer)

        nativeSpaceKeyForTests = spaceB
        let currentNativeWindowIds: Set<UInt32> = [3, 4]

        XCTAssertFalse(shouldCheckWindowLivenessInCurrentNativeSpace(oldWindow, currentNativeWindowIds: currentNativeWindowIds))
        XCTAssertFalse(shouldCheckWindowLivenessInCurrentNativeSpace(oldPopup, currentNativeWindowIds: currentNativeWindowIds))
        XCTAssertTrue(shouldCheckWindowLivenessInCurrentNativeSpace(currentWindow, currentNativeWindowIds: currentNativeWindowIds))
        XCTAssertTrue(shouldCheckWindowLivenessInCurrentNativeSpace(currentPopup, currentNativeWindowIds: currentNativeWindowIds))

        nativeSpaceKeyForTests = spaceA
        XCTAssertTrue(shouldCheckWindowLivenessInCurrentNativeSpace(
            currentWindow,
            snapshotNativeSpaceKey: spaceB,
            currentNativeWindowIds: currentNativeWindowIds,
        ))
    }

    func testSetUpWorkspacesForTestsClearsGlobalContainers() {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-clear-global-containers"))
        TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        TestWindow.new(id: 2, parent: macosPopupWindowsContainer)

        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-clear-global-containers"))

        assertEquals(macosMinimizedWindowsContainer.children, [])
        assertEquals(macosPopupWindowsContainer.children, [])
    }

    func testUnavailableNativeSpaceDoesNotCreatePersistentWorkspaces() {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        config.persistentWorkspaces = ["1", "2"]

        refreshModel()
        gcMonitors()
        updateTrayText()

        assertEquals(Workspace.all, [])
        assertEquals(TrayMenuModel.shared.trayText, NativeSpaceKey.unavailable.raw)
        assertEquals(TrayMenuModel.shared.workspaces, [])
        assertEquals(TrayMenuModel.shared.trayItems, [])
    }

    func testUnavailableNativeSpaceSkipsNativeFocusedWindowLookupInRefreshSessions() async throws {
        setUpWorkspacesForTests()
        let app = NativeSpacesFocusedAppProbe()
        appForTests = app
        nativeSpaceKeyForTests = .unavailable

        await runHeavyCompleteRefreshSession(.ax("test"), cancellable: false)
        let result = try await runLightSession(.ax("test"), .forceRun) { "ok" }

        assertEquals(result, "ok")
        assertEquals(app.focusedWindowLookups, 0)
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceListCommandsDoNotCreateWorkspaces() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        config.persistentWorkspaces = ["1", "2"]

        let windows = try await parseCommand("list-windows --all --count").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let workspaces = try await parseCommand("list-workspaces --all --count").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(windows.stdout, ["0"])
        assertEquals(workspaces.stdout, ["0"])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceBlocksMutatingCommands() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let result = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(result.stderr, ["Native macOS Space is unavailable"])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceWindowMembershipBlocksMutatingCommands() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-membership-unavailable"))
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true

        let result = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(result.stderr, ["Native macOS Space is unavailable"])
        assertEquals(userWorkspaceNames(), [])
    }

    func testNonUserNativeSpaceBlocksMutatingCommands() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-fullscreen-space"))
        isCurrentNativeSpaceUserForTests = false
        currentNativeSpaceIdsForTests = [100]
        currentNativeSpaceWindowIdsForTests = [1]

        let result = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(result.stderr, ["Native macOS Space is unavailable"])
        assertEquals(userWorkspaceNames(), [])
    }

    func testNonUserNativeSpaceDoesNotExposeWindowsOrRebindMovedWindows() {
        let oldSpace = NativeSpaceKey(raw: "test-fullscreen-old-space")
        let fullscreenSpace = NativeSpaceKey(raw: "test-fullscreen-space")

        setUpWorkspacesForTests(nativeSpaceKey: oldSpace)
        let oldWorkspace = Workspace.get(byName: "old")
        TestWindow.new(id: 1, parent: oldWorkspace.rootTilingContainer)

        nativeSpaceKeyForTests = fullscreenSpace
        isCurrentNativeSpaceUserForTests = false
        currentNativeSpaceIdsForTests = [200]
        nativeSpaceIdsForWindowIdForTests[1] = [200]

        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))
        XCTAssertFalse(isWindowInCurrentNativeSpace(windowId: 1))
        XCTAssertNil(Window.get(byId: 1))
    }

    func testUnavailableNativeSpaceWindowMembershipDoesNotCreatePersistentWorkspaces() {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-membership-unavailable"))
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true
        config.persistentWorkspaces = ["1", "2"]

        Workspace.garbageCollectUnusedWorkspaces()
        refreshModel()
        gcMonitors()
        updateTrayText()

        assertEquals(userWorkspaceNames(), [])
        assertEquals(TrayMenuModel.shared.trayText, NativeSpaceKey.unavailable.raw)
        assertEquals(TrayMenuModel.shared.workspaces, [])
        assertEquals(TrayMenuModel.shared.trayItems, [])
    }

    func testUnavailableNativeSpaceWindowMembershipListCommandsDoNotCreateWorkspaces() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-membership-unavailable"))
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true

        let windows = try await parseCommand("list-windows --workspace named --count").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let workspaces = try await parseCommand("list-workspaces --all --count").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(windows.stdout, ["0"])
        assertEquals(workspaces.stdout, ["0"])
        assertEquals(userWorkspaceNames(), [])
    }

    func testUnavailableNativeSpaceAllowsNonTreeCommands() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let result = try await parseCommand("mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceBlocksMutatingModeChangeCallback() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        activeMode = mainModeId
        config.modes["test-mode"] = Mode(bindings: [:])
        config.onModeChanged = [parseCommand("workspace 2").cmdOrDie]

        let result = try await parseCommand("mode test-mode").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceAllowsExecAndForget() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let result = try await parseCommand("exec-and-forget true").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceAllowsEnableCommand() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let off = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let on = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(off.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(on.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(off.stderr, [])
        assertEquals(on.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceBlocksEnableModeChangeCallback() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        activeMode = mainModeId
        config.onModeChanged = [parseCommand("workspace 2").cmdOrDie]

        let result = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceAllowsSafeTriggerBinding() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        let binding = HotkeyBinding([], .a, [parseCommand("mode main").cmdOrDie])
        config.modes[mainModeId] = Mode(bindings: [binding.descriptionWithKeyCode: binding])

        let result = try await parseCommand("trigger-binding --mode main a").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceBlocksMutatingTriggerBinding() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable
        let binding = HotkeyBinding([], .b, [parseCommand("workspace 2").cmdOrDie])
        config.modes[mainModeId] = Mode(bindings: [binding.descriptionWithKeyCode: binding])

        let result = try await parseCommand("trigger-binding --mode main b").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(result.stderr, ["Native macOS Space is unavailable"])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceWindowMembershipAllowsNonTreeCommands() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-membership-unavailable"))
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true

        let result = try await parseCommand("mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, EXIT_CODE_ZERO)
        assertEquals(result.stderr, [])
        assertEquals(userWorkspaceNames(), [])
    }

    func testNativeSpacesDebugJsonReportsCurrentWindowMembershipUnavailable() {
        let nativeSpaceKey = NativeSpaceKey(raw: "test-debug-window-membership-unavailable")
        setUpWorkspacesForTests(nativeSpaceKey: nativeSpaceKey)
        currentNativeSpaceIdsForTests = [200, 100]
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true

        let json = nativeSpacesDebugJson().asDictOrDie

        assertEquals(json["current-native-space-key"]?.asStringOrNil, nativeSpaceKey.raw)
        assertEquals(json["current-native-space-is-user"]?.asBoolOrNil, true)
        assertEquals(json["current-spaces"]?.asArrayOrNil, [
            .dict(["display-identifier": .string("test"), "space-id": .int(100), "space-kind": .string("unknown"), "space-type": .null]),
            .dict(["display-identifier": .string("test"), "space-id": .int(200), "space-kind": .string("unknown"), "space-type": .null]),
        ])
        assertEquals(json["current-space-window-ids-unavailable"]?.asBoolOrNil, true)
        assertEquals(json["current-space-window-ids"]?.asArrayOrNil, [])
        assertEquals(json["window-spaces-unavailable-window-ids"]?.asArrayOrNil, [])
        XCTAssertNotNil(json["window-spaces-api-timed-out"]?.asBoolOrNil)
    }

    func testNativeSpacesDebugJsonReportsNonUserCurrentNativeSpace() {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-debug-fullscreen-space"))
        isCurrentNativeSpaceUserForTests = false

        let json = nativeSpacesDebugJson().asDictOrDie

        assertEquals(json["current-native-space-is-user"]?.asBoolOrNil, false)
    }

    func testNativeSpaceKindMapsKnownSkyLightTypes() {
        assertEquals(nativeSpaceKind(fromSpaceType: 0), "user")
        assertEquals(nativeSpaceKind(fromSpaceType: 4), "fullscreen")
        assertEquals(nativeSpaceKind(fromSpaceType: nil), "unknown")
        assertEquals(nativeSpaceKind(fromSpaceType: 99), "unknown-99")
    }

    func testNativeSpacesDebugJsonReportsUnavailableNativeSpaceWindowMembershipUnavailable() {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let json = nativeSpacesDebugJson().asDictOrDie

        assertEquals(json["current-native-space-key"]?.asStringOrNil, NativeSpaceKey.unavailable.raw)
        assertEquals(json["current-space-window-ids-unavailable"]?.asBoolOrNil, true)
        assertEquals(json["current-space-window-ids"]?.asArrayOrNil, [])
    }

    func testNativeSpacesDebugJsonUsesTestWindowMembership() {
        let nativeSpaceKey = NativeSpaceKey(raw: "test-debug-window-spaces")
        setUpWorkspacesForTests(nativeSpaceKey: nativeSpaceKey)
        currentNativeSpaceWindowIdsForTests = [1, 2, 3]
        nativeSpaceIdsForWindowIdForTests[1] = [200]
        nativeSpaceIdsForWindowIdForTests[2] = [400, 300]

        let json = nativeSpacesDebugJson().asDictOrDie

        assertEquals(json["current-native-space-key"]?.asStringOrNil, nativeSpaceKey.raw)
        assertEquals(json["current-space-window-ids"]?.asArrayOrNil, [.int(1), .int(2), .int(3)])
        assertEquals(json["multi-space-window-ids"]?.asArrayOrNil, [.int(2)])
        assertEquals(json["window-spaces-unavailable-window-ids"]?.asArrayOrNil, [.int(3)])
        assertEquals(json["window-spaces"]?.asDictOrDie, [
            "1": .array([.int(200)]),
            "2": .array([.int(300), .int(400)]),
            "3": .string("unavailable"),
        ])
    }

    func testUnavailableNativeSpaceBlocksListMonitorWorkspaceFilters() async throws {
        setUpWorkspacesForTests()
        nativeSpaceKeyForTests = .unavailable

        let focused = try await parseCommand("list-monitors --focused").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let mouse = try await parseCommand("list-monitors --mouse").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(focused.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(focused.stderr, ["Native macOS Space is unavailable"])
        assertEquals(mouse.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(mouse.stderr, ["Native macOS Space is unavailable"])
        assertEquals(Workspace.all, [])
    }

    func testUnavailableNativeSpaceWindowMembershipBlocksListMonitorWorkspaceFilters() async throws {
        setUpWorkspacesForTests(nativeSpaceKey: NativeSpaceKey(raw: "test-window-membership-unavailable"))
        isCurrentNativeSpaceWindowMembershipUnavailableForTests = true

        let focused = try await parseCommand("list-monitors --focused").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let mouse = try await parseCommand("list-monitors --mouse").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(focused.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(focused.stderr, ["Native macOS Space is unavailable"])
        assertEquals(mouse.exitCode.rawValue, EXIT_CODE_TWO)
        assertEquals(mouse.stderr, ["Native macOS Space is unavailable"])
        assertEquals(userWorkspaceNames(), [])
    }

    func testMovedWindowRebindSkipsStickyWindows() {
        let spaceA = NativeSpaceKey(raw: "test-rebind-a")
        let spaceB = NativeSpaceKey(raw: "test-rebind-b")

        setUpWorkspacesForTests(nativeSpaceKey: spaceA)
        let oldWorkspace = Workspace.get(byName: "old")

        nativeSpaceKeyForTests = spaceB
        nativeSpaceIdsForWindowIdForTests[1] = [100, 200]
        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))

        nativeSpaceIdsForWindowIdForTests[1] = []
        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))

        nativeSpaceIdsForWindowIdForTests[1] = [200]
        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))

        currentNativeSpaceIdsForTests = [200]
        nativeSpaceIdsForWindowIdForTests[1] = [300]
        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))

        nativeSpaceIdsForWindowIdForTests[1] = [200]
        XCTAssertTrue(shouldRebindWindowToCurrentNativeSpace(from: oldWorkspace, windowId: 1))
    }

    func testDisplayTupleSwitchDoesNotRebindWindowOnUnchangedDisplay() {
        let oldTuple = NativeSpaceKey(raw: "external:7072|built-in:3907")
        let newTuple = NativeSpaceKey(raw: "external:7072|built-in:5005")

        setUpWorkspacesForTests(nativeSpaceKey: oldTuple)
        let externalWorkspace = Workspace.get(byName: "external")

        nativeSpaceKeyForTests = newTuple
        currentNativeSpaceIdsForTests = [7072, 5005]
        nativeSpaceIdsForWindowIdForTests[1] = [7072]
        XCTAssertFalse(shouldRebindWindowToCurrentNativeSpace(from: externalWorkspace, windowId: 1))

        nativeSpaceIdsForWindowIdForTests[1] = [5005]
        XCTAssertTrue(shouldRebindWindowToCurrentNativeSpace(from: externalWorkspace, windowId: 1))
    }

    func testDisplayTupleSwitchKeepsUnchangedDisplayWindowVisible() async throws {
        let oldTuple = NativeSpaceKey(raw: "external:7072|built-in:3907")
        let newTuple = NativeSpaceKey(raw: "external:7072|built-in:5005")

        setUpWorkspacesForTests(nativeSpaceKey: oldTuple)
        TestWindow.new(id: 1, parent: Workspace.get(byName: "external").rootTilingContainer)
        TestWindow.new(id: 2, parent: Workspace.get(byName: "built-in-old").rootTilingContainer)

        nativeSpaceKeyForTests = newTuple
        currentNativeSpaceIdsForTests = [7072, 5005]
        nativeSpaceIdsForWindowIdForTests[1] = [7072]
        nativeSpaceIdsForWindowIdForTests[2] = [3907]

        XCTAssertNotNil(Window.get(byId: 1))
        XCTAssertNil(Window.get(byId: 2))

        let result = try await parseCommand("list-windows --all --count").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, ["1"])
    }

    func testDisplayTupleSwitchChecksLivenessForUnchangedDisplayWindow() {
        let oldTuple = NativeSpaceKey(raw: "external:7072|built-in:3907")
        let newTuple = NativeSpaceKey(raw: "external:7072|built-in:5005")

        setUpWorkspacesForTests(nativeSpaceKey: oldTuple)
        let externalWindow = TestWindow.new(id: 1, parent: Workspace.get(byName: "external").rootTilingContainer)
        let oldBuiltInWindow = TestWindow.new(id: 2, parent: Workspace.get(byName: "built-in-old").rootTilingContainer)

        nativeSpaceKeyForTests = newTuple
        currentNativeSpaceIdsForTests = [7072, 5005]
        nativeSpaceIdsForWindowIdForTests[1] = [7072]
        nativeSpaceIdsForWindowIdForTests[2] = [3907]

        XCTAssertTrue(shouldCheckWindowLivenessInCurrentNativeSpace(
            externalWindow,
            snapshotNativeSpaceKey: newTuple,
            currentNativeWindowIds: [1],
        ))
        XCTAssertFalse(shouldCheckWindowLivenessInCurrentNativeSpace(
            oldBuiltInWindow,
            snapshotNativeSpaceKey: newTuple,
            currentNativeWindowIds: [1],
        ))
    }

    private func userWorkspaceNames() -> [String] {
        Workspace.all.map(\.name).filter { $0 != "setUpWorkspacesForTests" }
    }
}

private final class NativeSpacesFocusedAppProbe: AbstractApp {
    let pid: Int32 = -1
    let rawAppBundleId: String? = "bobko.AeroSpace.native-spaces-focused-app-probe"
    let name: String? = "native-spaces-focused-app-probe"
    let execPath: String? = nil
    let bundlePath: String? = nil
    var focusedWindowLookups = 0

    @MainActor
    func getFocusedWindow() async throws -> Window? {
        focusedWindowLookups += 1
        return TestWindow.new(id: 999, parent: Workspace.get(byName: "created-by-focused-lookup").rootTilingContainer)
    }
}

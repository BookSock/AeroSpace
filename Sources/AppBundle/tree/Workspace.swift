import AppKit
import Common

private struct WorkspaceLookupKey: Hashable {
    let nativeSpaceKey: NativeSpaceKey
    // periphery:ignore - Used by synthesized Hashable/Equatable conformance.
    let name: String
}

private struct NativeScreenPointKey: Hashable {
    let nativeSpaceKey: NativeSpaceKey
    let point: CGPoint
}

@MainActor private var workspaceNameToWorkspace: [WorkspaceLookupKey: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [NativeScreenPointKey: String] = [:]
@MainActor private var screenPointToVisibleWorkspace: [NativeScreenPointKey: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

@MainActor func resetWorkspaceStateForTests() {
    check(isUnitTest)
    for workspace in workspaceNameToWorkspace.values {
        for child in workspace.children {
            child.unbindFromParent()
        }
    }
    workspaceNameToWorkspace = [:]
    screenPointToPrevVisibleWorkspace = [:]
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]
}

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    getStubWorkspace(forPoint: monitor.rect.topLeftCorner)
}

@MainActor
private func getStubWorkspace(forPoint point: CGPoint) -> Workspace {
    let pointKey = NativeScreenPointKey(nativeSpaceKey: currentNativeSpaceKey, point: point)
    if let prev = screenPointToPrevVisibleWorkspace[pointKey].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.workspaceMonitor.rect.topLeftCorner == point && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isVisible && $0.workspaceMonitor.rect.topLeftCorner == point })
    {
        return candidate
    }
    return (1 ... Int.max).lazy
        .map { Workspace.get(byName: String($0)) }
        .first { $0.isEffectivelyEmpty && !$0.isVisible && !config.persistentWorkspaces.contains($0.name) && $0.forceAssignedMonitor == nil }
        .orDie("Can't create empty workspace")
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    let name: String
    let nativeSpaceKey: NativeSpaceKey
    nonisolated private let nameLogicalSegments: StringLogicalSegments
    /// `assignedMonitorPoint` must be interpreted only when the workspace is invisible
    fileprivate var assignedMonitorPoint: CGPoint? = nil

    @MainActor
    private init(_ name: String, nativeSpaceKey: NativeSpaceKey) {
        self.name = name
        self.nativeSpaceKey = nativeSpaceKey
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    @MainActor static var all: [Workspace] {
        workspaceNameToWorkspace.values
            .filter { $0.nativeSpaceKey == currentNativeSpaceKey }
            .sorted()
    }

    @MainActor static func get(byName name: String) -> Workspace {
        let key = WorkspaceLookupKey(nativeSpaceKey: currentNativeSpaceKey, name: name)
        if let existing = workspaceNameToWorkspace[key] {
            return existing
        } else {
            let workspace = Workspace(name, nativeSpaceKey: key.nativeSpaceKey)
            workspaceNameToWorkspace[key] = workspace
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nativeSpaceKey == rhs.nativeSpaceKey
            ? lhs.nameLogicalSegments < rhs.nameLogicalSegments
            : lhs.nativeSpaceKey < rhs.nativeSpaceKey
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        workspaceMonitor.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("nativeSpaceKey", nativeSpaceKey.raw),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        if isNativeSpaceStateUnavailableForMutation {
            return
        }
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            workspace.nativeSpaceKey != currentNativeSpaceKey ||
                config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name && lhs.nativeSpaceKey == rhs.nativeSpaceKey), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(nativeSpaceKey)
        hasher.combine(name)
    }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorPoint?.monitorApproximation
            ?? mainMonitor
    }
}

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        let key = NativeScreenPointKey(nativeSpaceKey: currentNativeSpaceKey, point: rect.topLeftCorner)
        if let existing = screenPointToVisibleWorkspace[key] {
            return existing
        }
        // What if monitor configuration changed? (frame.origin is changed)
        rearrangeWorkspacesOnMonitors()
        // Normally, recursion should happen only once more because we must take the value from the cache
        // (Unless, monitor configuration data race happens)
        return self.activeWorkspace
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

@MainActor
func gcMonitors() {
    if isNativeSpaceStateUnavailableForMutation {
        return
    }
    if visibleWorkspaceCountInCurrentNativeSpace != monitors.count {
        rearrangeWorkspacesOnMonitors()
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        let nativeSpaceKey = currentNativeSpaceKey
        let thisPointKey = NativeScreenPointKey(nativeSpaceKey: nativeSpaceKey, point: self)
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            let prevMonitorPointKey = NativeScreenPointKey(nativeSpaceKey: nativeSpaceKey, point: prevMonitorPoint)
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToPrevVisibleWorkspace[prevMonitorPointKey] =
                screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPointKey)?.name
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[thisPointKey] {
            screenPointToPrevVisibleWorkspace[thisPointKey] =
                screenPointToVisibleWorkspace.removeValue(forKey: thisPointKey)?.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[thisPointKey] = workspace
        workspace.assignedMonitorPoint = self
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors() {
    let nativeSpaceKey = currentNativeSpaceKey
    let newScreens = monitors.map(\.rect.topLeftCorner)
    var newScreenToOldScreenMapping: [CGPoint: CGPoint] = [:]
    for (key, _) in screenPointToVisibleWorkspace where key.nativeSpaceKey == nativeSpaceKey {
        let oldScreen = key.point
        guard let newScreen = newScreens.minBy({ ($0 - oldScreen).vectorLength }) else { continue }
        if let prevOldScreen = newScreenToOldScreenMapping[newScreen] {
            if (prevOldScreen - newScreen).vectorLength <= (oldScreen - newScreen).vectorLength {
                // newScreen has already been assigned to a closer oldScreen.
                continue
            }
        }
        newScreenToOldScreenMapping[newScreen] = oldScreen
    }

    let oldScreenPointToVisibleWorkspace = Dictionary(uniqueKeysWithValues: screenPointToVisibleWorkspace.compactMap { key, workspace in
        key.nativeSpaceKey == nativeSpaceKey ? (key.point, workspace) : nil
    })
    let keysToRemove = screenPointToVisibleWorkspace.keys.filter { $0.nativeSpaceKey == nativeSpaceKey }
    for key in keysToRemove {
        let workspace = screenPointToVisibleWorkspace[key]
        screenPointToVisibleWorkspace.removeValue(forKey: key)
        if let workspace {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
        }
    }

    for newScreen in newScreens {
        if let existingVisibleWorkspace = newScreenToOldScreenMapping[newScreen].flatMap({ oldScreenPointToVisibleWorkspace[$0] }),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            continue
        }
        let stubWorkspace = getStubWorkspace(forPoint: newScreen)
        check(newScreen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(newScreen)")
    }
}

@MainActor
private func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    switch workspace.forceAssignedMonitor {
        case let forceAssigned? where forceAssigned.rect.topLeftCorner != screen: false
        case _ where workspace.nativeSpaceKey != currentNativeSpaceKey: false
        default: true
    }
}

@MainActor
private var visibleWorkspaceCountInCurrentNativeSpace: Int {
    screenPointToVisibleWorkspace.keys.count { $0.nativeSpaceKey == currentNativeSpaceKey }
}

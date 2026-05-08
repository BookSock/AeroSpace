import AppKit
import Common
import PrivateApi

struct NativeSpaceKey: Hashable, Comparable, Sendable {
    let raw: String

    static let global = NativeSpaceKey(raw: "global")
    static let unavailable = NativeSpaceKey(raw: "native-space-unavailable")

    static func < (lhs: NativeSpaceKey, rhs: NativeSpaceKey) -> Bool {
        lhs.raw < rhs.raw
    }
}

private struct NativeSpaceSnapshot {
    let key: NativeSpaceKey
    let spaceIds: Set<UInt64>
    let isUserSpace: Bool
}

struct NativeSpaceWindowSnapshot {
    let key: NativeSpaceKey
    let windowIds: Set<UInt32>
}

@MainActor
var isExperimentalNativeSpacesEnabled: Bool {
    !isUnitTest && config.experimentalNativeSpaces
}

@MainActor
var nativeSpaceKeyForTests: NativeSpaceKey?
@MainActor
var nativeSpaceIdsForWindowIdForTests: [UInt32: Set<UInt64>] = [:]
@MainActor
var currentNativeSpaceIdsForTests: Set<UInt64>?
@MainActor
var currentNativeSpaceWindowIdsForTests: Set<UInt32>?
@MainActor
var isCurrentNativeSpaceUserForTests = true
@MainActor
var isCurrentNativeSpaceWindowMembershipUnavailableForTests = false

@MainActor
var currentNativeSpaceKey: NativeSpaceKey {
    if let nativeSpaceKeyForTests { return nativeSpaceKeyForTests }
    if !isExperimentalNativeSpacesEnabled { return .global }
    return readCurrentNativeSpaceKey() ?? .unavailable
}

@MainActor
var isCurrentNativeSpaceUnavailable: Bool {
    (isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil) && currentNativeSpaceKey == .unavailable
}

@MainActor
var isNativeSpaceStateUnavailableForMutation: Bool {
    (isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil) && currentNativeSpaceWindowSnapshot() == nil
}

@MainActor
func currentNativeSpaceWindowIds() -> Set<UInt32>? {
    if nativeSpaceKeyForTests != nil {
        return isCurrentNativeSpaceUnavailable || isCurrentNativeSpaceWindowMembershipUnavailableForTests
            ? nil
            : currentNativeSpaceWindowIdsForTests ?? []
    }
    guard isExperimentalNativeSpacesEnabled else { return nil }
    return readCurrentNativeSpaceWindowIds()
}

@MainActor
func currentNativeSpaceWindowSnapshot() -> NativeSpaceWindowSnapshot? {
    if nativeSpaceKeyForTests != nil {
        guard !isCurrentNativeSpaceUnavailable && isCurrentNativeSpaceUserForTests && !isCurrentNativeSpaceWindowMembershipUnavailableForTests else {
            return nil
        }
        return NativeSpaceWindowSnapshot(key: currentNativeSpaceKey, windowIds: currentNativeSpaceWindowIdsForTests ?? [])
    }
    guard isExperimentalNativeSpacesEnabled else { return nil }
    let snapshot = currentNativeSpaceSnapshot()
    guard snapshot.key != .unavailable else { return nil }
    guard snapshot.isUserSpace else { return nil }
    guard let windowIds = readNativeSpaceWindowIds(spaceIds: Array(snapshot.spaceIds)) else { return nil }
    return NativeSpaceWindowSnapshot(key: snapshot.key, windowIds: windowIds)
}

@MainActor
private func readCurrentNativeSpaceWindowIds() -> Set<UInt32>? {
    readNativeSpaceWindowIds(spaceIds: readCurrentSpaceIds())
}

@MainActor
private func readNativeSpaceWindowIds(spaceIds: [UInt64]) -> Set<UInt32>? {
    guard !spaceIds.isEmpty else { return nil }
    var result = Set<UInt32>()
    for spaceId in spaceIds {
        guard let rawWindows = unsafe aerospace_SLSCopyWindowsForSpace(spaceId) else { return nil }
        let windows = unsafe rawWindows.takeRetainedValue() as NSArray
        for case let windowId as NSNumber in windows {
            result.insert(windowId.uint32Value)
        }
    }
    return result
}

@MainActor
func nativeSpaceIds(forWindowId windowId: UInt32) -> Set<UInt64>? {
    if nativeSpaceKeyForTests != nil {
        return nativeSpaceIdsForWindowIdForTests[windowId]
    }
    guard isExperimentalNativeSpacesEnabled else { return nil }
    return readNativeSpaceIds(forWindowId: windowId)
}

@MainActor
func shouldRebindWindowToCurrentNativeSpace(from workspace: Workspace?, windowId: UInt32) -> Bool {
    guard isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil else { return false }
    guard let workspace else { return false }
    let snapshot = currentNativeSpaceSnapshot()
    guard snapshot.isUserSpace else { return false }
    guard workspace.nativeSpaceKey != snapshot.key else { return false }
    guard let windowSpaceIds = nativeSpaceIds(forWindowId: windowId), windowSpaceIds.count == 1 else { return false }
    if !windowSpaceIds.isDisjoint(with: nativeSpaceIds(encodedIn: workspace.nativeSpaceKey)) {
        return false
    }
    return windowSpaceIds.isSubset(of: snapshot.spaceIds)
}

@MainActor
func isWindowInCurrentNativeSpace(windowId: UInt32) -> Bool {
    guard isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil else { return true }
    guard let windowSpaceIds = nativeSpaceIds(forWindowId: windowId) else { return false }
    let snapshot = currentNativeSpaceSnapshot()
    guard snapshot.isUserSpace else { return false }
    return !windowSpaceIds.isDisjoint(with: snapshot.spaceIds)
}

@MainActor
func shouldCheckWindowLivenessInCurrentNativeSpace(
    _ window: Window,
    snapshotNativeSpaceKey: NativeSpaceKey? = nil,
    currentNativeWindowIds: Set<UInt32>?,
) -> Bool {
    guard isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil else { return true }
    let currentNativeSpaceKey = snapshotNativeSpaceKey ?? currentNativeSpaceKey
    if let workspace = window.visualWorkspace {
        return workspace.nativeSpaceKey == currentNativeSpaceKey || currentNativeWindowIds?.contains(window.windowId) == true
    }
    return currentNativeWindowIds?.contains(window.windowId) == true
}

@MainActor
func workspaceHasWindowInCurrentNativeSpace(_ workspace: Workspace) -> Bool {
    guard isExperimentalNativeSpacesEnabled || nativeSpaceKeyForTests != nil else { return false }
    return workspace.allLeafWindowsRecursive.contains { isWindowInCurrentNativeSpace(windowId: $0.windowId) }
}

@MainActor
private func readNativeSpaceIds(forWindowId windowId: UInt32) -> Set<UInt64>? {
    guard let rawSpaces = unsafe aerospace_SLSCopySpacesForWindow(windowId) else { return nil }
    let spaces = unsafe rawSpaces.takeRetainedValue() as NSArray
    return Set(spaces.compactMap { ($0 as? NSNumber)?.uint64Value })
}

@MainActor
private func currentNativeSpaceSnapshot() -> NativeSpaceSnapshot {
    if let nativeSpaceKeyForTests {
        return NativeSpaceSnapshot(
            key: nativeSpaceKeyForTests,
            spaceIds: currentNativeSpaceIdsForTests ?? [],
            isUserSpace: isCurrentNativeSpaceUserForTests,
        )
    }
    let rows = readCurrentSpaceRows()
    return NativeSpaceSnapshot(
        key: nativeSpaceKey(from: rows) ?? .unavailable,
        spaceIds: Set(rows.map(\.spaceId)),
        isUserSpace: !rows.isEmpty && rows.allSatisfy(\.isUserSpace),
    )
}

@MainActor
func nativeSpacesDebugJson() -> Json {
    let currentRows = nativeSpaceKeyForTests == nil
        ? readCurrentSpaceRows()
        : currentNativeSpaceIdsForTests.map { ids in ids.sorted().map { CurrentSpaceRow(displayIdentifier: "test", spaceId: $0, spaceType: nil) } } ?? []
    let debugCurrentNativeSpaceKey = nativeSpaceKeyForTests ?? nativeSpaceKey(from: currentRows) ?? .unavailable
    let isDebugCurrentNativeSpaceUser = nativeSpaceKeyForTests == nil
        ? !currentRows.isEmpty && currentRows.allSatisfy(\.isUserSpace)
        : isCurrentNativeSpaceUserForTests
    let rawCurrentWindowIds = nativeSpaceKeyForTests == nil
        ? readNativeSpaceWindowIds(spaceIds: currentRows.map(\.spaceId))
        : currentNativeSpaceWindowIds()
    let currentWindowIds = rawCurrentWindowIds ?? []
    var windowSpaces: [String: Json] = [:]
    var multiSpaceWindowIds: [UInt32] = []
    var unavailableWindowSpaceIds: [UInt32] = []
    for windowId in currentWindowIds.sorted() {
        guard let spaces = nativeSpaceIdsForDebug(forWindowId: windowId) else {
            unavailableWindowSpaceIds.append(windowId)
            windowSpaces[String(windowId)] = .string("unavailable")
            continue
        }
        if spaces.count > 1 {
            multiSpaceWindowIds.append(windowId)
        }
        windowSpaces[String(windowId)] = .array(spaces.sorted().map(jsonInt))
    }
    return .dict([
        "enabled": .bool(isExperimentalNativeSpacesEnabled),
        "current-native-space-key": .string(debugCurrentNativeSpaceKey.raw),
        "current-native-space-is-user": .bool(isDebugCurrentNativeSpaceUser),
        "namespace-kind": .string("display-space-tuple"),
        "screens-have-separate-spaces": .bool(NSScreen.screensHaveSeparateSpaces),
        "current-spaces": .array(currentRows.map {
            .dict([
                "display-identifier": .string($0.displayIdentifier),
                "space-id": jsonInt($0.spaceId),
                "space-kind": .string($0.spaceKind),
                "space-type": $0.spaceType.map(Json.int) ?? .null,
            ])
        }),
        "current-space-window-ids": .array(currentWindowIds.sorted().map { .int($0) }),
        "current-space-window-ids-unavailable": .bool(rawCurrentWindowIds == nil),
        "multi-space-window-ids": .array(multiSpaceWindowIds.map { .int($0) }),
        "window-spaces-api-timed-out": .bool(aerospace_SLSCopySpacesForWindowsDidTimeout()),
        "window-spaces-unavailable-window-ids": .array(unavailableWindowSpaceIds.map { .int($0) }),
        "window-spaces": .dict(windowSpaces),
    ])
}

@MainActor
private func nativeSpaceIdsForDebug(forWindowId windowId: UInt32) -> Set<UInt64>? {
    if nativeSpaceKeyForTests != nil {
        return nativeSpaceIdsForWindowIdForTests[windowId]
    }
    return readNativeSpaceIds(forWindowId: windowId)
}

@MainActor
private func readCurrentNativeSpaceKey() -> NativeSpaceKey? {
    nativeSpaceKey(from: readCurrentSpaceRows())
}

private func nativeSpaceKey(from rows: [CurrentSpaceRow]) -> NativeSpaceKey? {
    let parts = rows
        .map { "\($0.displayIdentifier):\($0.spaceId)" }
    return parts.isEmpty ? nil : NativeSpaceKey(raw: parts.joined(separator: "|"))
}

private func nativeSpaceIds(encodedIn key: NativeSpaceKey) -> Set<UInt64> {
    Set(key.raw.split(separator: "|").compactMap { part in
        part.split(separator: ":").last.flatMap { UInt64($0) }
    })
}

@MainActor
private func readCurrentSpaceIds() -> [UInt64] {
    readCurrentSpaceRows().map(\.spaceId)
}

private struct CurrentSpaceRow: Comparable {
    let displayIdentifier: String
    let spaceId: UInt64
    let spaceType: Int?

    var spaceKind: String {
        nativeSpaceKind(fromSpaceType: spaceType)
    }

    var isUserSpace: Bool {
        spaceType == 0
    }

    static func < (lhs: CurrentSpaceRow, rhs: CurrentSpaceRow) -> Bool {
        lhs.displayIdentifier == rhs.displayIdentifier
            ? lhs.spaceId < rhs.spaceId
            : lhs.displayIdentifier < rhs.displayIdentifier
    }
}

func nativeSpaceKind(fromSpaceType type: Int?) -> String {
    switch type {
        case 0: "user"
        case 4: "fullscreen"
        case nil: "unknown"
        case let type?: "unknown-\(type)"
    }
}

@MainActor
private func readCurrentSpaceRows() -> [CurrentSpaceRow] {
    guard let rawDisplays = unsafe aerospace_SLSCopyManagedDisplaySpaces() else { return [] }
    let displays = unsafe rawDisplays.takeRetainedValue() as NSArray
    return displays.compactMap { rawDisplay -> CurrentSpaceRow? in
        guard let display = rawDisplay as? NSDictionary else { return nil }
        guard let displayIdentifier = display["Display Identifier"] as? String else { return nil }
        guard let currentSpace = display["Current Space"] as? NSDictionary else { return nil }
        guard let spaceId = nativeSpaceId(from: currentSpace) else { return nil }
        let spaceType = (currentSpace["type"] as? NSNumber)?.intValue
        return CurrentSpaceRow(displayIdentifier: displayIdentifier, spaceId: spaceId, spaceType: spaceType)
    }.sorted()
}

private func nativeSpaceId(from space: NSDictionary) -> UInt64? {
    let value = space["ManagedSpaceID"] ?? space["id64"] ?? space["id"]
    return (value as? NSNumber)?.uint64Value
}

private func jsonInt(_ value: UInt64) -> Json {
    Int64(exactly: value).map(Json.int) ?? .string(String(value))
}

public struct DebugWindowsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .debugWindows,
        allowInConfig: false,
        help: debug_windows_help_generated,
        flags: [
            "--native-spaces": trueBoolFlag(\.nativeSpaces),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--native-spaces", "--window-id"],
        ],
    )

    public var nativeSpaces: Bool = false
}

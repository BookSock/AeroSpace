import AppKit
import Common

struct ModeCommand: Command {
    let args: ModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false
    /*conforms*/ let canRunWhenNativeSpaceUnavailable = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        try await activateMode(args.targetMode.val)
        return .succ
    }
}

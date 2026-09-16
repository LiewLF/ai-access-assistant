import Foundation

/// Only bounded categories are retained; process output and credentials stay out of receipts.
enum V011AgentLoopFailureReason: String, Codable, Equatable, Sendable {
    case timeout
    case launchFailed
    case outputLimit
    case processExit

    init?(commandError: Error) {
        switch commandError as? FableLiveAdapterError {
        case .commandTimedOut: self = .timeout
        case .commandLaunchFailed, .unsafeExecutable: self = .launchFailed
        case .commandOutputTooLarge: self = .outputLimit
        default: return nil
        }
    }

    var userTitle: String {
        switch self {
        case .timeout: return "真实任务验证超时"
        case .launchFailed: return "本机验证进程未能启动"
        case .outputLimit: return "真实任务证据未能完整读取"
        case .processExit: return "真实任务验证异常结束"
        }
    }

    var userAction: String {
        switch self {
        case .timeout:
            return "验证在等待时间内未完成；请求可能已经发出，是否消耗额度需以账户记录为准。查看诊断后再决定是否重试。"
        case .launchFailed:
            return "本机验证进程未能启动；请检查Codex安装与运行权限。"
        case .outputLimit:
            return "验证返回的数据过多，未能完整检查；请查看高级诊断。"
        case .processExit:
            return "Codex验证进程异常退出；现有证据不能确认具体原因或是否产生费用。请查看高级诊断。"
        }
    }
}

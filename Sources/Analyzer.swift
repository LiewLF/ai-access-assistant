import AppKit
import Foundation
import Vision

enum AdviceLevel: String {
    case recommended = "建议"
    case caution = "注意"
    case blocked = "不要操作"

    var symbol: String {
        switch self {
        case .recommended: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        }
    }
}

struct AdviceItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let level: AdviceLevel
    let source: String
}

struct AnalysisResult {
    let page: String
    let confidence: Int
    let summary: String
    let advice: [AdviceItem]
    let recognizedText: String
}

enum ScreenshotOCR {
    enum Failure: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            "图片无法解码"
        }
    }

    static func recognize(url: URL) throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.unreadableImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

enum KnowledgeAdvisor {
    private struct PageRule {
        let name: String
        let keywords: [String]
    }

    private static let pageRules: [PageRule] = [
        PageRule(name: "供应商配置", keywords: ["供应商配置", "Base URL", "Responses API", "Chat Completions", "API Key", "模型列表"]),
        PageRule(name: "Codex 增强", keywords: ["Codex增强", "兼容增强", "完整增强", "模型白名单", "Fast 按钮", "插件市场"]),
        PageRule(name: "工具与插件", keywords: ["工具与插件", "MCP", "Skills", "Plugins", "新增MCP"]),
        PageRule(name: "会话管理", keywords: ["会话管理", "历史会话修复", "本地会话", "数据库", "已归档"]),
        PageRule(name: "中转站环境配置检测", keywords: ["中转站环境配置检测", "Clash Verge", "TUN 模式", "代理环境变量", "Codex .env"]),
        PageRule(name: "概览", keywords: ["健康检查", "静默启动入口", "管理工具入口", "最近启动", "running_degraded"]),
    ]

    static func analyze(text: String, documentText: String = "") -> AnalysisResult {
        let merged = text + "\n" + documentText
        let scores = pageRules.map { rule in
            (rule, rule.keywords.reduce(0) { $0 + (merged.localizedCaseInsensitiveContains($1) ? 1 : 0) })
        }
        let best = scores.max { $0.1 < $1.1 }
        let page = best?.1 ?? 0 > 0 ? best!.0.name : "未识别页面"
        let confidence = min(98, 35 + (best?.1 ?? 0) * 12)

        return AnalysisResult(
            page: page,
            confidence: confidence,
            summary: summary(for: page),
            advice: advice(for: page, text: merged),
            recognizedText: text
        )
    }

    private static func summary(for page: String) -> String {
        switch page {
        case "供应商配置": return "决定认证边界、协议、模型列表与 Codex 实际请求路径。优先核对中转站明确支持项。"
        case "Codex 增强": return "增强模式必须匹配认证方式。功能越多，注入面和升级兼容风险越大。"
        case "工具与插件": return "MCP、Skills、Plugins 属全局能力层。供应商切换会合并选中项。"
        case "会话管理": return "涉及本地 SQLite 与 rollout 文件。删除、修复均属高风险操作。"
        case "中转站环境配置检测": return "检查 TUN、代理环境变量和 ~/.codex/.env 是否干扰中转请求。"
        case "概览": return "用于查看入口、版本、运行状态与桥接健康，不代表供应商请求必然可用。"
        default: return "截图文字不足。建议截取页面标题、字段名、当前选项；API Key 必须打码。"
        }
    }

    private static func advice(for page: String, text: String) -> [AdviceItem] {
        var items: [AdviceItem] = []

        switch page {
        case "供应商配置":
            items.append(AdviceItem(
                title: "协议先由中转站能力决定",
                detail: "文档若明确支持 Responses API，当前版本才允许接入Codex。只有 Chat Completions 或 Anthropic Messages 时明确提示不兼容，不生成虚假配置。",
                level: .recommended,
                source: "当前Codex版本合同与用户导入资料"
            ))
            items.append(AdviceItem(
                title: "Base URL 暂不猜",
                detail: "必须以用户导入的文档、文字或截图为准；没有证据时不要根据常见路径自行补 /v1。",
                level: .caution,
                source: "用户导入资料"
            ))
            items.append(AdviceItem(
                title: "模型名与窗口分开",
                detail: "模型名称、上下文窗口和压缩阈值分别核对；资料没有明确数据时显示未识别，由用户补充，不猜具体数值。",
                level: .recommended,
                source: "用户导入资料与当前配置"
            ))
            if text.localizedCaseInsensitiveContains("混入 API Key") || text.localizedCaseInsensitiveContains("混入 API KEY") {
                items.append(AdviceItem(
                    title: "当前像是官方登录混入 API",
                    detail: "此模式保留官方登录与插件入口，请求使用中转 Key；适合要保留官方能力。纯 API 才适合完全脱离官方账号。",
                    level: .caution,
                    source: "Codex++ README：供应商模式"
                ))
            }
        case "Codex 增强":
            items.append(AdviceItem(
                title: "官方登录或混入 API：兼容增强",
                detail: "兼容增强保留会话删除、导出、项目移动等能力，关闭插件市场相关增强，兼容风险较低。",
                level: .recommended,
                source: "用户截图与 Codex++ README"
            ))
            items.append(AdviceItem(
                title: "Fast 按钮保持关闭",
                detail: "源码界面说明 Fast 仅支持 gpt-5.4 / gpt-5.5。其他模型按 Standard 发送。",
                level: .recommended,
                source: "Codex++ 增强界面说明"
            ))
            items.append(AdviceItem(
                title: "Windows Computer Use Guard：Mac 不启用",
                detail: "此开关只服务 Windows Computer Use 配置保护。macOS 无需开启。",
                level: .recommended,
                source: "Codex++ 增强界面说明"
            ))
        case "工具与插件":
            items.append(AdviceItem(
                title: "只启用日常需要项目",
                detail: "每个 MCP 都增加启动、权限和失败面。先保留业务必需项；不因数量多判断配置更好。",
                level: .recommended,
                source: "Codex++ README：按供应商选择 MCP/Skill/Plugin"
            ))
            items.append(AdviceItem(
                title: "computer-use 默认关闭合理",
                detail: "只有需要控制本机应用时再开，并单独确认权限。普通配置分析无需启用。",
                level: .recommended,
                source: "用户截图"
            ))
        case "会话管理":
            items.append(AdviceItem(
                title: "不要为配置优化删除或修复会话",
                detail: "供应商配置与会话清理无直接关系。删除会同时改 SQLite 记录和 rollout 文件。",
                level: .blocked,
                source: "Codex++ README 与会话界面说明"
            ))
            items.append(AdviceItem(
                title: "自动修复仅在归属异常时使用",
                detail: "正常会话无需整理。操作前关闭对应会话窗口并确认备份。",
                level: .caution,
                source: "Codex++ 会话管理界面"
            ))
        case "中转站环境配置检测":
            items.append(AdviceItem(
                title: "三项检测是冲突筛查，不是连通性证明",
                detail: "通过只表示未发现 Clash Verge TUN、标准代理变量、~/.codex/.env。仍需供应商模型测试和一次真实请求。",
                level: .caution,
                source: "Codex++ relay_environment.rs"
            ))
            items.append(AdviceItem(
                title: "不要自动清理代理配置",
                detail: "代理可能服务其他软件。先解释冲突来源，再由用户决定。",
                level: .blocked,
                source: "本软件安全边界"
            ))
        case "概览":
            items.append(AdviceItem(
                title: "running_degraded 先看消息",
                detail: "截图显示 Codex 已启动，但页面桥仍等待。属于增强桥接状态，不等同中转 API 失败。",
                level: .caution,
                source: "用户概览截图"
            ))
            items.append(AdviceItem(
                title: "健康检查正常不代表模型可用",
                detail: "还要核对供应商协议、模型列表、Provider Doctor 和真实请求。",
                level: .recommended,
                source: "Codex++ README"
            ))
        default:
            items.append(AdviceItem(
                title: "重新截图",
                detail: "保留页面标题与选项，遮住 Key、账号、余额、会话 ID。",
                level: .caution,
                source: "本软件识别规则"
            ))
        }

        items.append(AdviceItem(
            title: "分析模式保持只读",
            detail: "截图分析不会读取或写入 ~/.codex。配置方案页面只有在预览并明确确认后才导出副本，仍不覆盖现有文件。",
            level: .recommended,
            source: "产品安全边界"
        ))
        return items
    }
}

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published var imageURL: URL?
    @Published var image: NSImage?
    @Published var documentText = ""
    @Published var result: AnalysisResult?
    @Published var isAnalyzing = false
    @Published var errorMessage: String?

    func loadImage(_ url: URL) {
        imageURL = url
        image = NSImage(contentsOf: url)
        result = nil
        errorMessage = image == nil ? "图片无法读取" : nil
    }

    func analyze() {
        guard let imageURL else {
            errorMessage = "先导入截图"
            return
        }
        isAnalyzing = true
        errorMessage = nil
        let importedDocument = documentText

        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotOCR.recognize(url: imageURL)
                }.value
                result = KnowledgeAdvisor.analyze(text: text, documentText: importedDocument)
            } catch {
                errorMessage = "识别失败：\(error.localizedDescription)"
            }
            isAnalyzing = false
        }
    }
}

import Foundation

/// Turns raw inspection facts into a root cause and graded fix suggestions.
/// Pure logic (no I/O) so it can be unit tested.
enum DiagnosisEngine {
    static func diagnose(_ r: InspectionReport) -> Diagnosis {
        guard r.exists else {
            return Diagnosis(title: "文件不存在或无法访问", explanation: "请确认文件仍在原位置，且本应用有读取权限。",
                             level: .failed, suggestions: [], advice: [], suggestOpenAnyway: false)
        }
        switch r.kind {
        case .app, .bundle: return diagnoseCode(r)
        case .dmg: return diagnoseDMG(r)
        case .pkg: return diagnosePKG(r)
        case .other: return diagnoseOther(r)
        }
    }

    // MARK: APP / bundle

    private static func diagnoseCode(_ r: InspectionReport) -> Diagnosis {
        var suggestions: [FixSuggestion] = []
        var advice: [String] = []
        let sig = r.signatureKind ?? .unknown
        let hasQuarantine = r.quarantinedItemCount > 0 || r.quarantinePresent

        if r.onReadOnlyVolume && r.kind == .app {
            suggestions.append(FixSuggestion(action: .copyToApplications, risk: .low,
                reason: "应用位于只读磁盘映像中，无法直接修改，也不建议在映像内直接运行。", recommended: true))
        }

        if r.architectureUnsupported {
            advice.append("此程序只包含 \(r.executableArchs.joined(separator: "/")) 架构，无法在本机（\(r.hostArch)）运行，请下载适配的版本。")
            return Diagnosis(title: "这台 Mac 无法运行它", explanation: "这不是安全拦截问题，移除标记或重签名都无法解决。",
                             level: .failed, suggestions: [], advice: advice, suggestOpenAnyway: false)
        }
        if r.systemTooOld, let min = r.minimumSystemVersion {
            advice.append("该应用要求 macOS \(min) 或更高版本，请升级系统或下载旧版本。")
        }
        if r.needsRosetta {
            advice.append("这是 Intel 应用，本机未安装 Rosetta 2。可在终端运行：softwareupdate --install-rosetta")
        }

        let resignEntitlementWarning = r.entitlementKeys.isEmpty ? "" :
            "\n⚠️ 该应用声明了 \(r.entitlementKeys.count) 项特殊权限（如虚拟化、系统扩展、iCloud 等），ad-hoc 重签名后这些功能很可能失效。"

        // 1. Signature itself is broken.
        if r.signatureValid == false {
            if sig.isCertificateSigned {
                advice.insert("最可靠的做法：从官网重新下载。下载中断、解压出错、被其他工具修改过都会导致原签名失效。", at: 0)
                if hasQuarantine {
                    suggestions.append(FixSuggestion(action: .clearQuarantine, risk: .medium,
                        reason: "先移除隔离标记，Gatekeeper 将不再拦截首次打开。", recommended: true))
                }
                suggestions.append(FixSuggestion(action: .adhocResign, risk: .high,
                    reason: "原开发者签名已失效，可以用本机临时签名替换。" + resignEntitlementWarning
                        + "\n⚠️ macOS 会记住它原本经过公证。重签名后双击仍会被拦截，需要再到“隐私与安全性”里点“仍要打开”放行（完成后本工具会引导你）。",
                    recommended: false))
                return Diagnosis(title: "应用签名已损坏",
                    explanation: "此应用原本由开发者签名，但现在文件内容和签名对不上。macOS 因此显示“已损坏，无法打开”。",
                    level: .failed, suggestions: suggestions, advice: advice, suggestOpenAnyway: true)
            }
            if hasQuarantine {
                suggestions.append(FixSuggestion(action: .clearQuarantine, risk: .medium,
                    reason: "移除浏览器添加的下载隔离标记。", recommended: true))
            }
            suggestions.append(FixSuggestion(action: .adhocResign, risk: .medium,
                reason: "应用未签名或临时签名不完整，重新生成本机签名后 Apple 芯片才能正常加载。" + resignEntitlementWarning,
                recommended: true))
            return Diagnosis(title: "应用没有有效签名",
                explanation: "常见于开源软件、个人开发者作品或被修改过的应用。带有下载标记时 macOS 会直接提示“已损坏”。",
                level: .warning, suggestions: suggestions, advice: advice, suggestOpenAnyway: true)
        }

        // 2. Signature is valid (or could not be checked).
        if hasQuarantine {
            if r.gatekeeperAccepted == true {
                suggestions.append(FixSuggestion(action: .clearQuarantine, risk: .low,
                    reason: "签名有效且系统评估通过，移除标记只是省去首次打开确认。", recommended: true))
                return Diagnosis(title: "应用正常，只是带有下载标记",
                    explanation: "如果仍提示“已损坏”，通常是内部文件残留了隔离标记，移除后再试。",
                    level: .passed, suggestions: suggestions, advice: advice, suggestOpenAnyway: false)
            }
            let risk: FixRisk = sig == .developerID ? .low : .medium
            suggestions.append(FixSuggestion(action: .clearQuarantine, risk: risk,
                reason: "签名完整，只是未被 Apple 公证或系统评估不通过。移除下载隔离标记即可打开。", recommended: true))
            let explanation: String
            switch sig {
            case .developerID:
                explanation = "应用由开发者正式签名且未被修改，但没有通过 Apple 公证或公证已被撤销。"
            case .adhoc, .unsigned:
                explanation = "应用只有临时签名（常见于开源软件），带下载标记时 macOS 会显示“已损坏”。"
            default:
                explanation = "签名完整，但 Gatekeeper 评估未通过。"
            }
            if r.gatekeeperAccepted == false && sig == .developerID {
                advice.append("如果是知名厂商的软件，Apple 撤销公证可能意味着该版本有安全问题，建议先到官网确认。")
            }
            return Diagnosis(title: "被 macOS 拦截了", explanation: explanation,
                             level: .warning, suggestions: suggestions, advice: advice, suggestOpenAnyway: true)
        }

        // 3. No quarantine, valid signature.
        if !advice.isEmpty {
            return Diagnosis(title: "系统环境不满足", explanation: "安全检查没有发现拦截原因，但存在兼容性问题。",
                             level: .warning, suggestions: suggestions, advice: advice, suggestOpenAnyway: false)
        }
        suggestions.append(FixSuggestion(action: .clearAllAttributes, risk: .low,
            reason: "如果仍无法打开，可清除残留的扩展属性后重试。", recommended: false))
        if r.signatureKind == .adhoc && r.gatekeeperAccepted == false && r.kind == .app {
            advice.append("如果双击仍提示“已损坏”，用下方“引导我放行”：在“隐私与安全性”里点“仍要打开”，只放行这一个应用。若放行后虚拟化、网络等特殊功能出错，再从官网重新下载安装。")
            return Diagnosis(title: "需要在系统设置里放行",
                explanation: "签名有效且没有下载隔离标记。原本就是开源或个人开发的软件，通常可以正常打开；原本正式签名、后来被重签名的软件则仍会被拦截。",
                level: .warning, suggestions: suggestions, advice: advice, suggestOpenAnyway: true)
        }
        return Diagnosis(title: "没有发现问题",
            explanation: "签名有效且没有下载隔离标记，macOS 不应再提示“已损坏”。若仍无法打开，可能是应用本身崩溃，请查看“控制台”中的崩溃报告。",
            level: .passed, suggestions: suggestions, advice: advice, suggestOpenAnyway: false)
    }

    // MARK: DMG / PKG / other

    private static func diagnoseDMG(_ r: InspectionReport) -> Diagnosis {
        if r.imageVerified == false || r.hashMatched == false {
            return Diagnosis(title: "安装包已损坏",
                explanation: r.hashMatched == false ? "SHA-256 与你填写的官方值不同，文件可能下载不完整或被替换。" : "hdiutil 校验失败，通常是下载不完整。",
                level: .failed, suggestions: [], advice: ["请重新下载该 DMG，不要尝试修复。"], suggestOpenAnyway: false)
        }
        return quarantineOnly(r, title: "安装包被 macOS 拦截了",
            note: "移除 DMG 的标记后，挂载出来的应用通常不会再继承标记。若挂载后其中的 APP 仍提示“已损坏”，请把那个应用单独拖进来。")
    }

    private static func diagnosePKG(_ r: InspectionReport) -> Diagnosis {
        if r.hashMatched == false {
            return Diagnosis(title: "安装包已损坏", explanation: "SHA-256 与你填写的官方值不同。",
                level: .failed, suggestions: [], advice: ["请重新下载该安装包。"], suggestOpenAnyway: false)
        }
        var d = quarantineOnly(r, title: "安装包被 macOS 拦截了", note: "移除标记后双击即可正常安装。")
        if r.pkgSigned == false {
            d = Diagnosis(title: "安装包没有签名", explanation: "安装包没有有效签名，安装器会以“无法验证开发者”或“已损坏”拒绝。" + d.explanation,
                          level: .warning, suggestions: d.suggestions.map {
                              FixSuggestion(action: $0.action, risk: .medium, reason: $0.reason, recommended: $0.recommended)
                          }, advice: d.advice, suggestOpenAnyway: true)
        }
        return d
    }

    private static func diagnoseOther(_ r: InspectionReport) -> Diagnosis {
        quarantineOnly(r, title: "文件被 macOS 拦截了",
            note: "命令行工具、脚本、插件等带有下载标记时会被系统拦截。")
    }

    private static func quarantineOnly(_ r: InspectionReport, title: String, note: String) -> Diagnosis {
        let hasQuarantine = r.quarantinedItemCount > 0 || r.quarantinePresent
        guard hasQuarantine else {
            return Diagnosis(title: "没有发现问题", explanation: "此文件没有被 Gatekeeper 隔离。" ,
                level: .passed, suggestions: [FixSuggestion(action: .clearAllAttributes, risk: .low,
                    reason: "如果仍无法打开，可清除残留扩展属性后重试。", recommended: false)],
                advice: [], suggestOpenAnyway: false)
        }
        let verified = r.hashMatched == true || r.pkgSigned == true || r.gatekeeperAccepted == true
        return Diagnosis(title: title, explanation: note, level: .warning,
            suggestions: [FixSuggestion(action: .clearQuarantine, risk: verified ? .low : .medium,
                reason: verified ? "完整性/签名已核对，移除标记风险较低。" : "确认来源可信后再移除。可先填写官方 SHA-256 降低风险。",
                recommended: true)],
            advice: [], suggestOpenAnyway: r.kind != .dmg)
    }
}

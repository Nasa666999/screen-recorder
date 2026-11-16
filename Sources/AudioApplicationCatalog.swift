import AppKit

enum AudioApplicationGroup: String, CaseIterable {
    case browser = "浏览器"
    case music = "音乐与播客"
    case video = "视频与媒体"
    case communication = "通话与通讯"
}

struct AudioApplicationChoice {
    let identifier: String
    let name: String
    let group: AudioApplicationGroup
    let isRunning: Bool
}

enum AudioApplicationCatalog {
    /// 业务作用: 根据应用登记的主要用途识别浏览器、媒体和通讯来源，避免把普通编辑器列为声音选项。
    /// 参数说明:
    /// - identifier: 应用真实的 Bundle Identifier。
    /// - information: 应用自身的 Info.plist 元数据。
    /// 返回: 支持的声音来源分组；用途不匹配时返回空，不代表应用绝对不会产生系统提示音。
    static func group(identifier: String, information: [String: Any]) -> AudioApplicationGroup? {
        switch identifier {
        case "com.apple.Safari", "com.google.Chrome":
            return .browser
        case "com.apple.podcasts", "com.apple.VoiceMemos", "com.apple.iBooksX":
            return .music
        case "com.apple.Photos", "com.obsproject.obs-studio":
            return .video
        case "com.apple.mobilephone", "com.larksuite.macos.lark", "us.zoom.xos":
            return .communication
        default:
            break
        }
        let category = information["LSApplicationCategoryType"] as? String
        switch category {
        case "public.app-category.music":
            return .music
        case "public.app-category.video":
            return .video
        case "public.app-category.social-networking":
            return .communication
        default:
            break
        }
        let urlTypes = information["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = Set(
            urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
        let documentTypes = information["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let contentTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let extensions = Set(
            documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }.map { $0.lowercased() })
        let handlesWebPages =
            !contentTypes.isDisjoint(with: ["public.html", "public.xhtml"])
            || !extensions.isDisjoint(with: ["html", "htm", "xhtml"])
        if schemes.isSuperset(of: ["http", "https"]), handlesWebPages,
            category != "public.app-category.developer-tools", category != "public.app-category.business"
        {
            return .browser
        }
        return nil
    }

    /// 业务作用: 合并已安装与运行中的声音应用，使尚未启动的浏览器和播放器也能被明确选择。
    /// 参数说明:
    /// - selected: 已保存的声音来源标识，用于查找安装在其它目录中的已选应用。
    /// 返回: 去重后的支持应用及真实运行状态；不启动应用、不改变声音范围或系统设备。
    @MainActor static func discover(selected: [String]) -> [AudioApplicationChoice] {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIdentifiers = Set(running.compactMap(\.bundleIdentifier))
        var urls = Set(running.compactMap(\.bundleURL))
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications", isDirectory: true),
        ]
        for root in roots {
            let installed =
                (try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls.formUnion(installed.filter { $0.pathExtension == "app" })
        }
        for identifier in Set(selected + ["com.apple.Safari", "com.google.Chrome"]) {
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
                urls.insert(url)
            }
        }
        var choices: [String: AudioApplicationChoice] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                let information = bundle.infoDictionary,
                let group = group(identifier: identifier, information: information)
            else {
                continue
            }
            let displayName =
                bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
                ?? FileManager.default.displayName(atPath: url.path)
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            choices[identifier] = AudioApplicationChoice(
                identifier: identifier, name: name, group: group,
                isRunning: runningIdentifiers.contains(identifier))
        }
        return choices.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

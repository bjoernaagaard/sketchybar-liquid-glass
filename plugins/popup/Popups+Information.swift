import AppKit

struct FrontSnapshot: Decodable, Equatable {
    let appName: String?
    let windowTitle: String?

    enum CodingKeys: String, CodingKey {
        case appName = "app-name", windowTitle = "window-title"
    }
}

extension Popups {
    func readFront() async -> FrontSnapshot? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/aerospace" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let result = try? await ProcessCapture().run(URL(fileURLWithPath: path),
                  ["list-windows", "--focused", "--json", "--format", "%{app-name} %{window-title}"]),
              !Task.isCancelled, result.status == 0,
              let windows = try? JSONDecoder().decode([FrontSnapshot].self, from: result.output) else { return nil }
        return windows.first
    }

    func refreshFront() {
        guard let target = lifecycle.target, target.kind == .front, isOpen, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let next = await self.readFront()
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id, self.isOpen else { return }
            self.refreshTask = nil
            if self.front != next { self.front = next; self.buildFront() }
        }
    }

    func buildFront() {
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: .front)
        let row = theme.number("POPUP_ROW")
        let view = surface(width: width, height: pad * 2 + row * 3)
        label("Front app", x: pad, y: pad, width: width - pad * 2, in: view)
        let name = front?.appName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable"
        let title = front?.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Window unavailable"
        label(name, x: pad, y: pad + row, width: width - pad * 2, in: view)
        label(title, x: pad, y: pad + row * 2, width: width - pad * 2, color: "TEXT2", in: view)
    }

    func refreshInformation() {
        guard let target = lifecycle.target, isOpen, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let next = await self.readInformation(target.source)
            guard !Task.isCancelled, self.lifecycle.target?.id == target.id, self.isOpen else { return }
            self.refreshTask = nil
            if target.kind == .mode, next == nil { self.dismiss(suppress: false); return }
            let lines = next ?? ["Unavailable"]
            if self.information != lines { self.information = lines; self.buildInformation() }
        }
    }

    func readInformation(_ source: PopupSource) async -> [String]? {
        let capture = ProcessCapture()
        if source.kind == .battery {
            guard let result = try? await capture.run(URL(fileURLWithPath: "/usr/bin/pmset"), ["-g", "batt"]),
                  !Task.isCancelled, result.status == 0 else { return nil }
            let output = String(decoding: result.output, as: UTF8.self)
            let lines = output.components(separatedBy: .newlines)
            var values: [String] = []
            if let first = lines.first {
                if first.contains("AC Power") { values.append("AC Power") }
                else if first.contains("Battery Power") { values.append("Battery Power") }
            }
            let pattern = try? NSRegularExpression(pattern: "([0-9]+)%|([0-9]+:[0-9]{2}) remaining")
            let range = NSRange(output.startIndex..., in: output)
            for match in pattern?.matches(in: output, range: range) ?? [] {
                if let r = Range(match.range, in: output) { values.append(String(output[r])) }
            }
            return values.isEmpty ? nil : values
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ "\($0)/aerospace" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let executable = URL(fileURLWithPath: path)
        if case .workspace(let id, _) = source {
            guard let result = try? await capture.run(executable, ["list-windows", "--workspace", id, "--json", "--format", "%{app-name}"]),
                  !Task.isCancelled, result.status == 0,
                  let windows = try? JSONSerialization.jsonObject(with: result.output) as? [[String: Any]] else { return nil }
            var counts: [String: Int] = [:]
            for window in windows {
                let name = (window["app-name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown app"
                counts[name, default: 0] += 1
            }
            if counts.isEmpty { return ["No windows"] }
            return counts.keys.sorted().map { "\($0)  \(counts[$0] ?? 0)" }
        }
        if source.kind == .mode {
            guard let current = try? await capture.run(executable, ["list-modes", "--current"]),
                  !Task.isCancelled, current.status == 0 else { return ["Unavailable"] }
            let mode = String(decoding: current.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mode.isEmpty, mode != "main" else { return nil }
            guard mode.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  let result = try? await ProcessCapture().run(executable, ["config", "--get", "mode.\(mode).binding", "--json"]),
                  !Task.isCancelled, result.status == 0,
                  let bindings = try? JSONSerialization.jsonObject(with: result.output) as? [String: String] else { return [mode, "Unavailable"] }
            let safeActions: Set<String> = ["mode main", "resize width -50", "resize width +50", "resize height -50",
                                            "resize height +50", "balance-sizes", "flatten-workspace-tree",
                                            "close-all-windows-but-current", "join-with left", "join-with right",
                                            "join-with up", "join-with down"]
            return [mode] + bindings.keys.sorted().map { key in
                let action = bindings[key] ?? ""
                let commands = action.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                return commands.allSatisfy { safeActions.contains($0) } ? "\(key)  \(action)" : key
            }
        }
        return nil
    }

    func buildInformation() {
        guard let source = lifecycle.target?.source else { return }
        let title: String
        switch source {
        case .battery: title = "Battery"
        case .workspace(let id, _): title = "Workspace \(id)"
        case .mode: title = "Mode"
        default: return
        }
        let pad = theme.number("POPUP_PADDING")
        let width = theme.width(for: source.kind)
        let row = theme.number("POPUP_ROW")
        let view = surface(width: width, height: pad * 2 + row * CGFloat(1 + information.count))
        label(title, x: pad, y: pad, width: width - pad * 2, in: view)
        for (index, line) in information.enumerated() {
            label(line, x: pad, y: pad + row * CGFloat(index + 1), width: width - pad * 2, color: "TEXT2", in: view)
        }
    }
}

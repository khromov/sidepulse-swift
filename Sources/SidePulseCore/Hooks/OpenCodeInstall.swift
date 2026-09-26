import Darwin
import Foundation

/// OpenCode has no shell-hook config, so SidePulse owns one global plugin file that turns OpenCode's
/// event stream into `hook-log` records.
public enum OpenCodePluginInstaller {
    /// A file is ours only with this exact line, so a user's own `sidepulse.js` is never replaced or deleted.
    public static let marker = "// sidepulse hook-log --provider opencode"
    static let cliLinePrefix = "const CLI = "

    public static func isSidePulsePlugin(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == marker }
    }

    public static func cliPath(in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(cliLinePrefix) }) else { return nil }
        return (try? JSONValue.parse(String(line.dropFirst(cliLinePrefix.count))))?.stringValue
    }

    /// Looks for the quoted event names, so a plugin written by an older SidePulse shows as partial.
    public static func installedEvents(in text: String) -> [String] {
        HookProvider.opencode.events.filter { text.contains("\"\($0)\"") }
    }

    /// Doctor compares the whole file with `source`, because a logic change keeps every event name.
    public static let outdatedProblem = "written by another SidePulse version; run 'sidepulse install opencode' to update it"

    public static func install(paths: SidePulsePaths, cliPath: String, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let file = paths.openCodePluginFile
        let desired = source(cliPath: cliPath)
        let original = try HookConfigFile.read(file)
        if let original, !isSidePulsePlugin(original) { throw HookInstallError.notOurs(path: file.path) }
        let changed = original != desired
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(desired, to: file, now: now)
        }
        let notes = dryRun ? [] : [versionProblem(paths: paths)].compactMap { $0 }
        return InstallResult(provider: .opencode, configPath: file, changed: changed, backupPath: backup, dryRun: dryRun, notes: notes)
    }

    /// Needs no backup because install regenerates the file.
    public static func uninstall(paths: SidePulsePaths, dryRun: Bool) throws -> InstallResult {
        let file = paths.openCodePluginFile
        guard let original = try HookConfigFile.read(file) else {
            return InstallResult(provider: .opencode, configPath: file, changed: false, dryRun: dryRun)
        }
        guard isSidePulsePlugin(original) else {
            return InstallResult(provider: .opencode, configPath: file, changed: false, dryRun: dryRun,
                                 notes: ["left it alone: it was not written by SidePulse"])
        }
        if !dryRun {
            try FileUtil.ensureWritable(file)
            try FileManager.default.removeItem(at: file)
        }
        return InstallResult(provider: .opencode, configPath: file, changed: true, dryRun: dryRun)
    }

    /// `~/.opencode/bin` is where OpenCode's install script puts it, and the LaunchAgent's PATH may lack it.
    public static func findOpenCodeBinary(paths: SidePulsePaths) -> String? {
        let dirs = [paths.home.appendingPathComponent(".opencode/bin").path]
            + (paths.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return dirs.map { $0 + "/opencode" }.first { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// OpenCode 1.x expects a different plugin shape and would fail to load this one.
    public static func versionProblem(paths: SidePulsePaths) -> String? {
        guard let binary = findOpenCodeBinary(paths: paths), let version = version(of: binary),
              let major = Int(version.prefix { $0 != "." }), major < 2 else { return nil }
        return "OpenCode \(version) cannot load the SidePulse plugin; update to OpenCode 2 or later"
    }

    /// Reads without blocking after exit, so a leftover child holding the pipe open cannot hang install.
    static func version(of binary: String, timeout: TimeInterval = 5) -> String? {
        autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return nil }
            guard exited.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                return nil
            }
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            return parseVersion(String(decoding: buffer[0..<count], as: UTF8.self))
        }
    }

    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: { $0.isWhitespace }).lazy
            .map { $0.hasPrefix("v") ? $0.dropFirst() : $0 }
            .first { $0.first?.isNumber == true && $0.contains(".") }
            .map(String.init)
    }

    /// The plugin subscribes to OpenCode's buffered event stream instead of its awaited tool hooks, so it
    /// never slows OpenCode down; it never throws and never writes to stdout.
    public static func source(cliPath: String) -> String {
        let cli = JSONValue.string(cliPath).serialized()
        return #"""
        // Managed by SidePulse: `sidepulse install opencode` rewrites this file and `sidepulse uninstall opencode` deletes it.
        \#(marker)
        import { spawn } from "node:child_process"

        \#(cliLinePrefix)\#(cli)
        const ORIGIN = { agent_origin: "OpenCode", agent_origin_kind: "opencode", agent_origin_source: "plugin", agent_origin_confidence: "explicit" }
        // OpenCode loads this module once per project directory and every copy sees every event, so state is per process.
        const S = (globalThis.__sidepulseOpenCode1 ??= { seen: new Set(), sessions: new Map(), tools: new Map(), queue: [], running: false })

        function bounded(collection, max) {
          for (const key of collection.keys()) { if (collection.size <= max) break; collection.delete(key) }
        }

        // hook-log trims these fields anyway; capping them here keeps a pasted file under the CLI's stdin limit.
        function cut(text, max) {
          return typeof text === "string" && text.length > max ? text.slice(0, max) : text
        }

        // One CLI at a time, because two CLIs started back to back can append their records out of order.
        function send(record) {
          S.queue.push(JSON.stringify({ ...record, ...ORIGIN }))
          if (S.queue.length > 200) S.queue.shift()
          if (!S.running) next()
        }

        function next() {
          const payload = S.queue.shift()
          if (!(S.running = payload !== undefined)) return
          let done = false
          const finish = () => { if (!done) { done = true; clearTimeout(timer); next() } }
          const timer = setTimeout(finish, 2000)
          timer.unref?.()
          try {
            const child = spawn(CLI, ["hook-log", "--provider", "opencode"], { detached: true, stdio: ["pipe", "ignore", "ignore"] })
            child.on("error", finish).on("exit", finish).unref()
            child.stdin.on("error", () => {})
            child.stdin.end(payload)
          } catch { finish() }
        }

        // Re-inserting keeps the map in least-recently-used order, so the bound drops idle sessions first.
        function session(id) {
          const s = S.sessions.get(id) ?? { text: [] }
          S.sessions.delete(id)
          S.sessions.set(id, s)
          bounded(S.sessions, 500)
          return s
        }

        // Subagent sessions report under their root session, like Claude subagents.
        function base(id, name) {
          const s = session(id)
          let root = id
          for (let depth = 0; S.sessions.get(root)?.parent && depth < 8; depth++) root = S.sessions.get(root).parent
          return { hook_event_name: name, session_id: root, cwd: s.dir, ...(root === id ? {} : { agent_id: id, agent_type: s.agent }) }
        }

        function tool(callID) {
          const t = S.tools.get(callID) ?? {}
          return { tool_name: t.name, ...(t.command === undefined ? {} : { tool_input: { command: t.command } }) }
        }

        // Streaming events such as session.text.delta arrive per token and have no handler, so they cost nothing.
        const on = {
          __proto__: null,
          "session.created"(d, id, s) {
            Object.assign(s, { parent: d.parentID, agent: d.agent })
            if (!d.parentID) send(base(id, "SessionStart"))
          },
          "session.inbox.enqueued"(d, id, s) {
            if (d.item?.type !== "user" || s.parent) return
            const prompt = cut(d.item.payload?.text, 8000)
            if (s.busy) send({ ...base(id, "UserPromptSubmit"), prompt })
            else s.prompt = prompt
          },
          "session.execution.started"(d, id, s) {
            send({ ...base(id, s.parent ? "SubagentStart" : "UserPromptSubmit"), prompt: s.prompt })
            Object.assign(s, { busy: true, prompt: undefined, text: [], message: undefined })
          },
          "session.text.ended"(d, id, s) {
            if (s.message !== d.assistantMessageID) Object.assign(s, { message: d.assistantMessageID, text: [] })
            s.text[d.ordinal ?? s.text.length] = d.text
          },
          "session.tool.input.started"(d) {
            S.tools.set(d.id, { name: d.name })
            bounded(S.tools, 500)
          },
          "session.tool.called"(d, id) {
            // Only the shell command is kept, because other tool inputs can hold whole files.
            const command = typeof d.input?.command === "string" ? cut(d.input.command, 4000) : undefined
            S.tools.set(d.id, { ...S.tools.get(d.id), command })
            send({ ...base(id, "PreToolUse"), ...tool(d.id) })
          },
          "session.tool.success"(d, id) {
            const { exit, status } = d.metadata ?? {}
            const response = typeof exit === "number" ? { exit_code: exit } : status === "timeout" || status === "killed" ? { interrupted: true } : undefined
            send({ ...base(id, "PostToolUse"), ...tool(d.id), tool_response: response })
            S.tools.delete(d.id)
          },
          "session.tool.failed"(d, id) {
            send({ ...base(id, "PostToolUseFailure"), ...tool(d.id), error: cut(d.error?.message, 1000) })
            S.tools.delete(d.id)
          },
          "permission.asked"(d, id) {
            send({ ...base(id, "PermissionRequest"), ...tool(d.source?.id), message: cut(`OpenCode needs permission: ${d.action} ${(d.resources ?? []).join(", ")}`, 4000) })
          },
          "form.created"(d, id) {
            send({ ...base(id, "PermissionRequest"), ...tool(d.form.metadata?.tool?.id), message: cut(`OpenCode is asking: ${d.form.fields?.[0]?.description ?? d.form.title}`, 4000) })
          },
          "session.compaction.started"(d, id) {
            send(base(id, "PreCompact"))
          },
          "session.compaction.ended"(d, id) {
            send(base(id, "PostCompact"))
          },
          "session.execution.succeeded"(d, id, s) {
            send({ ...base(id, s.parent ? "SubagentStop" : "Stop"), last_assistant_message: s.text.filter(Boolean).join("\n\n").slice(-1000000) })
            Object.assign(s, { busy: false, text: [], message: undefined })
          },
          "session.execution.failed"(d, id, s) {
            s.busy = false
            send({ ...base(id, "StopFailure"), error: cut(d.error?.type, 1000), error_details: cut(d.error?.message, 1000) })
          },
          "session.execution.interrupted"(d, id, s) {
            s.busy = false
            send({ ...base(id, "Interrupt"), reason: d.reason })
          },
          // Deleting an old session from OpenCode's list must not show it as a finished session.
          "session.deleted"(d, id, s, known) {
            if (known && !s.parent) send(base(id, "SessionEnd"))
            S.sessions.delete(id)
          },
        }

        export default {
          id: "sidepulse",
          async setup(ctx) {
            const abort = new AbortController()
            ;(async () => {
              for await (const ev of ctx.event.subscribe({ signal: abort.signal })) {
                const handler = on[ev?.type], d = ev?.data ?? {}, id = d.sessionID ?? d.form?.sessionID
                if (!handler || !id || !ev.id || S.seen.has(ev.id)) continue
                S.seen.add(ev.id)
                bounded(S.seen, 2000)
                try {
                  const known = S.sessions.has(id), s = session(id)
                  s.dir = d.location?.directory ?? s.dir ?? ev.location?.directory
                  handler(d, id, s, known)
                } catch {}
              }
            })().catch(() => {})
            return () => abort.abort()
          },
        }

        """#
    }
}

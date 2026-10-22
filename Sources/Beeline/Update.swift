import Foundation

enum Update {
    enum Check: Equatable {
        case refused(String)
        case upToDate(head: String, reachedGitHub: Bool)
        case offer(incoming: [String], hasLocalEdits: Bool, head: String)
    }

    /// Never changes the source folder: it only fetches and looks.
    static func check(root: String, built: String) -> Check {
        let branch = shell("git rev-parse --abbrev-ref HEAD", in: root)
        guard branch.ok else {
            return .refused("Beeline's source folder isn't a git checkout, so there is nothing to fetch from.")
        }
        let branchName = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchName == "main" else {
            return .refused("The source folder is on the branch “\(branchName)”. Update only installs main; switch branches in Terminal first.")
        }
        let reachedGitHub = shell("git fetch --quiet origin", in: root, timeout: 60).ok
        let incoming = shell("git log --oneline HEAD..origin/main", in: root).output
            .split(whereSeparator: \.isNewline).map(String.init)
        let head = shell("git rev-parse HEAD", in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLocalEdits = !shell("git status --porcelain --untracked-files=no", in: root).output.isEmpty
        if incoming.isEmpty, !head.isEmpty, head == built, !hasLocalEdits {
            return .upToDate(head: head, reachedGitHub: reachedGitHub)
        }
        return .offer(incoming: incoming, hasLocalEdits: hasLocalEdits, head: head)
    }

    /// Moves main forward only if that needs no merge. Returns why not, or nil when it moved.
    static func fastForward(root: String) -> String? {
        let merged = shell("git merge --ff-only --quiet origin/main", in: root)
        guard !merged.ok else { return nil }
        return merged.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "git merge failed"
    }

    /// A login shell, because an app opened from Finder doesn't get the terminal's PATH or git credentials.
    static func shell(_ command: String, in directory: String, timeout: TimeInterval = 30) -> (ok: Bool, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (false, "", error.localizedDescription) }
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        var errors = ""
        let errorsRead = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errors = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            errorsRead.signal()
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        errorsRead.wait()
        if timedOut { errors += "\nGave up after \(Int(timeout)) seconds." }
        return (process.terminationStatus == 0 && !timedOut, output, errors)
    }
}

import Foundation
import Darwin

/// No command text is evaluated by a shell. Captured diagnostics stay in memory.
struct CodexProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var outputWasTruncated: Bool
    var diagnostic: String { String(decoding: stderr + stdout, as: UTF8.self).lowercased() }
}

enum CodexProcessRunner {
    static func run(executable: URL, arguments: [String], directory: URL,
                    input: Data = Data(), timeout: TimeInterval,
                    outputLimit: Int = 512 * 1024) async throws -> CodexProcessResult {
        let operation = CodexProcessOperation(executable: executable, arguments: arguments,
            directory: directory, input: input, timeout: timeout, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
    }

    static var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        // Keep login/provider and OS networking configuration, without forwarding unrelated
        // application credentials to the child. Codex reads its own credential store.
        let keys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
            "CODEX_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        var result = inherited.filter { keys.contains($0.key) }
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var paths = (inherited["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for path in fallback where !paths.contains(path) { paths.append(path) }
        result["PATH"] = paths.joined(separator: ":")
        result["NO_COLOR"] = "1"
        return result
    }
}

/// A serial queue owns the process and both nonblocking pipe readers. In particular,
/// a chatty stderr can never block stdout, cancellation, or the deadline timer.
private final class CodexProcessOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SideBrief.codex-process")
    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let input: Data
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var continuation: CheckedContinuation<CodexProcessResult, Error>?
    private var process: Process?
    private var ownedProcessGroup: pid_t?
    private var groupCleanupScheduled = false
    private var exitStatus: Int32?
    private var inputHandle: FileHandle?
    private var inputURL: URL?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false
    private var outputEnded = false
    private var errorEnded = false
    private var cancelled = false
    private var finished = false
    private var stopError: Error?
    private var deadline: DispatchWorkItem?

    init(executable: URL, arguments: [String], directory: URL, input: Data,
         timeout: TimeInterval, outputLimit: Int) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
        self.input = input; self.timeout = timeout; self.outputLimit = outputLimit
    }

    func start(_ continuation: CheckedContinuation<CodexProcessResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if cancelled { finish(.failure(CancellationError())); return }
            do {
                // A private regular file supplies stdin, avoiding SIGPIPE or a blocked writer
                // if a broken executable exits without reading the prompt.
                let inputURL = directory.appendingPathComponent("stdin-\(UUID().uuidString)")
                self.inputURL = inputURL
                try input.write(to: inputURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                inputHandle = try FileHandle(forReadingFrom: inputURL)
                let child = Process()
                child.executableURL = executable
                child.arguments = arguments
                child.currentDirectoryURL = directory
                child.environment = CodexProcessRunner.environment
                child.standardInput = inputHandle
                let out = Pipe(), err = Pipe()
                outputPipe = out; errorPipe = err
                child.standardOutput = out; child.standardError = err
                process = child
                outputSource = makeReader(out.fileHandleForReading, isError: false)
                errorSource = makeReader(err.fileHandleForReading, isError: true)
                child.terminationHandler = { [weak self] child in
                    self?.queue.async { [weak self] in self?.didExit(status: child.terminationStatus) }
                }
                try child.run()
                // Foundation creates a separate process group on macOS. Verify ownership
                // before signalling it; never signal the application's own process group.
                let pid = child.processIdentifier
                if getpgid(pid) == pid { ownedProcessGroup = pid }
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                let deadline = DispatchWorkItem { [weak self] in self?.stop(CodexError.timedOut) }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
            } catch {
                finish(.failure(CodexError.cannotLaunch))
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { stop(CancellationError()) }
        }
    }

    private func makeReader(_ handle: FileHandle, isError: Bool) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd, isError: isError) }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func drain(_ fd: Int32, isError: Bool) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work per event, so a continuously-writing child cannot starve the deadline.
        for _ in 0..<64 {
            let count = read(fd, &bytes, bytes.count)
            if count == 0 {
                if isError { errorEnded = true; errorSource?.cancel() }
                else { outputEnded = true; outputSource?.cancel() }
                return
            }
            guard count > 0 else { return }
            let remaining = max(0, outputLimit - (isError ? stderr.count : stdout.count))
            let kept = min(count, remaining)
            if isError { stderr.append(contentsOf: bytes.prefix(kept)) }
            else { stdout.append(contentsOf: bytes.prefix(kept)) }
            if kept < count { truncated = true }
        }
    }

    private func stop(_ error: Error) {
        guard !finished else { return }
        if stopError == nil { stopError = error }
        if let group = ownedProcessGroup, kill(-group, 0) == 0 {
            stopGroup(group)
            return
        }
        guard let child = process, child.isRunning else {
            finish(.failure(stopError ?? error)); return
        }
        child.terminate()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak child] in
            guard let self, !self.finished, let child, child.isRunning else { return }
            _ = kill(child.processIdentifier, SIGKILL)
        }
    }

    private func didExit(status: Int32) {
        guard !finished else { return }
        exitStatus = status
        if !outputEnded, let pipe = outputPipe { drain(pipe.fileHandleForReading.fileDescriptor, isError: false) }
        if !errorEnded, let pipe = errorPipe { drain(pipe.fileHandleForReading.fileDescriptor, isError: true) }
        // An npm wrapper can exit before its native Codex child. Clean up the owned
        // group even then, and finish only after descendants have been signalled.
        if let group = ownedProcessGroup, kill(-group, 0) == 0 {
            stopGroup(group)
            return
        }
        completeExit(status: status)
    }

    private func stopGroup(_ group: pid_t) {
        guard !groupCleanupScheduled else { return }
        groupCleanupScheduled = true
        _ = kill(-group, SIGTERM)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.finished else { return }
            if kill(-group, 0) == 0 { _ = kill(-group, SIGKILL) }
            self.ownedProcessGroup = nil
            if let status = self.exitStatus { self.completeExit(status: status) }
            // Otherwise Foundation's termination handler completes after reaping the child.
        }
    }

    private func completeExit(status: Int32) {
        if let stopError { finish(.failure(stopError)) }
        else { finish(.success(.init(status: status, stdout: stdout, stderr: stderr, outputWasTruncated: truncated))) }
    }

    private func finish(_ result: Result<CodexProcessResult, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        outputSource?.cancel(); errorSource?.cancel()
        outputSource = nil; errorSource = nil
        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()
        try? inputHandle?.close(); inputHandle = nil
        if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
        process?.terminationHandler = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}

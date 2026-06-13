import Dispatch
import Foundation
import os

let sharedEnv = Environment.shared

func getEnvExportString(env: [String: String]) -> String {
    let dict = sharedEnv.systemEnvStr.merging(env) { current, _ in current }
    let shell = sharedEnv.userLoginShell.lowercased()

    // Check for tcsh/csh
    if shell.contains("tcsh") || shell.contains("csh") {
        // tcsh/csh uses: setenv VAR value
        return dict.map { "setenv \($0.key) \($0.value.quoteIfNeeded())" }.joined(separator: "; ")
    }

    // Check for fish
    if shell.contains("fish") {
        // fish uses: set -x VAR value
        return dict.map { "set -x \($0.key) \($0.value.quoteIfNeeded())" }.joined(separator: "; ")
    }

    // Default to bash/zsh/sh syntax: export VAR=value
    return "export \(dict.map { "\($0.key)=\($0.value.quoteIfNeeded())" }.joined(separator: " "))"
}

func buildTerminalCommand(script: String, args: [String] = [], env: [String: String] = [:]) -> String {
    let command = ([script.escaped()] + args.map { $0.quoteIfNeeded() }).joined(separator: " ")
    return "\(getEnvExportString(env: env)); \(command)"
}

/// Launches a script and returns its stdout/stderr output.
///
/// - Parameter workingDirectory: If non-nil, sets `Process.currentDirectoryURL`
///   so the script runs with this as its working directory (used by packaged plugins).
@discardableResult func runScript(to command: String,
                                  args: [String] = [],
                                  process: Process = Process(),
                                  env: [String: String] = [:],
                                  workingDirectory: String? = nil,
                                  runInBash: Bool = true,
                                  streamOutput: Bool = false,
                                  stdinPipe: Pipe? = nil,
                                  onOutputUpdate: @escaping (String?) -> Void = { _ in }) throws -> (out: String, err: String?)
{
    let swiftbarEnv = sharedEnv.systemEnvStr.merging(env) { _, new in new }
    process.environment = swiftbarEnv.merging(ProcessInfo.processInfo.environment) { current, _ in current }
    if let workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    return try process.launchScript(with: command, args: args, runInBash: runInBash, streamOutput: streamOutput, stdinPipe: stdinPipe, onOutputUpdate: onOutputUpdate)
}

// Code below is adopted from https://github.com/JohnSundell/ShellOut

/// Error type thrown by the `shellOut()` function, in case the given command failed
public struct ShellOutError: Swift.Error {
    /// The termination status of the command that was run
    public let terminationStatus: Int32
    /// The error message as a UTF8 string, as returned through `STDERR`
    public var message: String { errorData.shellOutput() }
    /// The raw error buffer data, as returned through `STDERR`
    public let errorData: Data
    /// The raw output buffer data, as retuned through `STDOUT`
    public let outputData: Data
    /// The output of the command as a UTF8 string, as returned through `STDOUT`
    public var output: String { outputData.shellOutput() }
}

// MARK: - Private

private extension Process {
    @discardableResult func launchScript(with script: String, args: [String], runInBash: Bool = true, streamOutput: Bool, stdinPipe: Pipe? = nil, onOutputUpdate: @escaping (String?) -> Void) throws -> (out: String, err: String?) {
        if !runInBash {
            executableURL = URL(fileURLWithPath: script)
            arguments = args
        } else {
            let shell = delegate.prefs.shell
            executableURL = URL(fileURLWithPath: shell.path)
            // When executing in a shell, we need to properly escape arguments to handle special characters
            let escapedArgs = args.map { $0.quoteIfNeeded() }
            arguments = ["-c", "\(script.escaped()) \(escapedArgs.joined(separator: " "))"]
            if shell.path.hasSuffix("bash") || shell.path.hasSuffix("zsh") {
                arguments?.insert("-l", at: 1)
            }
        }

        guard let executableURL, FileManager.default.fileExists(atPath: executableURL.path) else {
            return (out: "", err: nil)
        }

        var outputData = Data()
        var errorData = Data()

        let outputPipe = Pipe()
        standardOutput = outputPipe

        let errorPipe = Pipe()
        standardError = errorPipe

        // Set up stdin pipe if provided
        if let stdinPipe = stdinPipe {
            standardInput = stdinPipe
        }

        guard streamOutput else { // horrible hack, code below this guard doesn't work reliably and I can't fugire out why.
            do {
                try run()
            } catch {
                os_log("Failed to launch plugin", log: Log.plugin, type: .error)
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                throw ShellOutError(terminationStatus: terminationStatus, errorData: errorData, outputData: data)
            }

            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            waitUntilExit()

            if terminationStatus != 0 {
                throw ShellOutError(
                    terminationStatus: terminationStatus,
                    errorData: errorData,
                    outputData: outputData
                )
            }
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let err = String(data: errorData, encoding: .utf8)
            return (out: output, err: err)
        }

        let outputQueue = DispatchQueue(label: "bash-output-queue")

        // Use terminationHandler as the authoritative signal that the
        // plugin subprocess has exited, instead of relying on
        // `waitUntilExit()` to also implicitly tear down the pipe
        // readers. This avoids the "Unable to obtain a task name port
        // right for pid N: (os/kern) failure (0x5)" error that happens
        // when the readability handlers are still pulling from the
        // pipe's file descriptor at the moment the kernel reaps the
        // child — the handlers race the kernel's task-port cleanup
        // and the kernel wins, leaving us with a stale dispatch.
        //
        // We hop back to the output queue (the same serial queue the
        // readability handlers use) to clear the handlers, so the
        // teardown is fully serialised with the read loop and there
        // is no window in which the kernel can reap the child while a
        // handler is mid-call.
        terminationHandler = { _ in
            outputQueue.async {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            // Empty data = EOF — the kernel has signalled close on the
            // write end of the pipe. Drop the handler so we don't
            // spin on the closed fd, and don't bother queueing the
            // empty data into `outputData`.
            if data.isEmpty {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            outputQueue.async {
                outputData.append(data)
                onOutputUpdate(String(data: data, encoding: .utf8))
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            if data.isEmpty {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            outputQueue.async {
                errorData.append(data)
            }
        }

        do {
            try run()
        } catch {
            os_log("Failed to launch plugin", log: Log.plugin, type: .error)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ShellOutError(terminationStatus: terminationStatus, errorData: errorData, outputData: outputData)
        }

        // The process is now running. `waitUntilExit()` will return as
        // soon as the kernel reaps the child. By the time it returns,
        // the terminationHandler has fired (it runs on a kernel-
        // managed dispatch queue) and our readability handlers have
        // been cleared inside the output queue.
        waitUntilExit()

        // Defensive: if for any reason the terminationHandler did
        // not clear the readers (e.g. an extremely fast exit that
        // raced the handler install), clear them now. This is a
        // no-op in the common path because the handler already ran.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        return try outputQueue.sync {
            if terminationStatus != 0 {
                throw ShellOutError(
                    terminationStatus: terminationStatus,
                    errorData: errorData,
                    outputData: outputData
                )
            }
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let err = String(data: errorData, encoding: .utf8)
            return (out: output, err: err)
        }
    }
}

private extension FileHandle {
    var isStandard: Bool {
        self === FileHandle.standardOutput ||
            self === FileHandle.standardError ||
            self === FileHandle.standardInput
    }
}

private extension Data {
    func shellOutput() -> String {
        guard let output = String(data: self, encoding: .utf8) else {
            return ""
        }

        guard !output.hasSuffix("\n") else {
            let endIndex = output.index(before: output.endIndex)
            return String(output[..<endIndex])
        }

        return output
    }
}

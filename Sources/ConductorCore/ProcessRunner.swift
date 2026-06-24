import Foundation

public struct ProcessResult: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum ProcessRunner {
    /// Run an executable with args, optionally in `cwd`, and capture its output.
    public static func run(_ executable: String, _ args: [String], cwd: String?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ProcessRunner.read", attributes: .concurrent)
        try process.run()
        // Drain both pipes concurrently so a large write to one cannot block the
        // child while we are reading the other (the classic pipe-buffer deadlock).
        queue.async(group: group) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        process.waitUntilExit()
        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

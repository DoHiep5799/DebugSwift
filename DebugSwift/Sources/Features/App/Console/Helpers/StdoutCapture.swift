//
//  StdoutCapture.swift
//  DebugSwift
//
//  Created by Matheus Gois on 19/12/23.
//

import Foundation
import UIKit

// MARK: - StdoutCapture

/// Captures stdout at the file-descriptor level (`dup2` + pipe) so `print` and C writes to fd 1
/// are mirrored into the DebugSwift console even when the Xcode debugger is not attached.
/// Replacing only `stdout.pointee._write` is unreliable off-debugger because libc/Swift may write
/// via `write(1, …)` or a `FILE` that does not go through the hooked `_write`.
final class StdoutCapture: @unchecked Sendable {
    static let shared = StdoutCapture()

    let logUrl: URL? = {
        if let path = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory,
            .userDomainMask,
            true
        ).first {
            let docs = URL(fileURLWithPath: path)
            return docs.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "app")-output.log")
        }
        return nil
    }()

    private let captureQueue = DispatchQueue(
        label: "com.debugswift.stdout.capture",
        qos: .utility
    )

    private let processingQueue = DispatchQueue(
        label: "com.debugswift.stdout.processing",
        qos: .utility,
        attributes: .concurrent
    )

    private let stateLock = NSLock()
    private var _isCapturing = false

    private var isCapturing: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCapturing
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCapturing = newValue
        }
    }

    private var inputPipe: Pipe?
    /// Duplicate of the original stdout sink (created before `dup2` redirects fd 1).
    private var savedStdoutFd: Int32 = -1

    private let lineBufferLock = NSLock()
    private var lineBuffer = Data()

    private init() {}

    // MARK: - Public API

    func startCapturing() {
        let instance = Self.shared
        Task { @MainActor in
            if let logUrl = instance.logUrl {
                do {
                    let header = """
                    Start logger
                    DeviceID: \(UIDevice.current.identifierForVendor?.uuidString ?? "none")
                    """
                    try header.write(to: logUrl, atomically: true, encoding: .utf8)
                } catch {
                    // Silent failure
                }
            }

            instance.captureQueue.async {
                instance.startCapturingInternal()
            }
        }
    }

    func stopCapturing() {
        captureQueue.async { [weak self] in
            self?.stopCapturingInternal()
        }
    }

    // MARK: - Private

    private func startCapturingInternal() {
        guard !isCapturing else { return }

        fflush(stdout)

        let saved = dup(FileHandle.standardOutput.fileDescriptor)
        guard saved >= 0 else {
            return
        }

        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            self.captureQueue.async { [weak self] in
                guard let self else { return }
                guard self.isCapturing, self.savedStdoutFd >= 0 else { return }

                let data = handle.availableData
                if data.isEmpty {
                    return
                }

                let forwardFd = self.savedStdoutFd
                data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    _ = write(forwardFd, base, data.count)
                }

                self.appendAndProcessLines(data)
            }
        }

        // Ready before redirect so the first bytes after dup2 always see a valid forward fd and active capture.
        savedStdoutFd = saved
        isCapturing = true

        setvbuf(stdout, nil, _IONBF, 0)

        let outFd = FileHandle.standardOutput.fileDescriptor
        let pipeWriteFd = pipe.fileHandleForWriting.fileDescriptor
        if dup2(pipeWriteFd, outFd) == -1 {
            isCapturing = false
            savedStdoutFd = -1
            close(saved)
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        inputPipe = pipe
    }

    private func stopCapturingInternal() {
        guard isCapturing else { return }
        isCapturing = false

        inputPipe?.fileHandleForReading.readabilityHandler = nil

        fflush(stdout)

        if savedStdoutFd >= 0 {
            let outFd = FileHandle.standardOutput.fileDescriptor
            _ = dup2(savedStdoutFd, outFd)
            close(savedStdoutFd)
            savedStdoutFd = -1
        }

        inputPipe = nil

        lineBufferLock.lock()
        lineBuffer.removeAll()
        lineBufferLock.unlock()
    }

    private func appendAndProcessLines(_ data: Data) {
        lineBufferLock.lock()
        lineBuffer.append(data)

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0a) {
            let rawLine = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex ... newlineIndex)

            guard !rawLine.isEmpty else { continue }
            if let line = String(data: Data(rawLine), encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    processingQueue.async { [weak self] in
                        self?.processCompleteLine(trimmed)
                    }
                }
            }
        }
        lineBufferLock.unlock()
    }

    private func processCompleteLine(_ line: String) {
        if let logUrl = logUrl {
            do {
                try line.appendLineToURL(logUrl)
            } catch {
                // Silent failure for file writing
            }
        }

        guard !shouldIgnoreLog(line), shouldIncludeLog(line) else { return }
        ConsoleOutput.shared.addPrintAndNSLogOutput(line)
    }

    private func shouldIgnoreLog(_ log: String) -> Bool {
        DebugSwift.Console.shared.ignoredLogs.contains { log.contains($0) }
    }

    private func shouldIncludeLog(_ log: String) -> Bool {
        if DebugSwift.Console.shared.onlyLogs.isEmpty {
            return true
        }
        return DebugSwift.Console.shared.onlyLogs.contains { log.contains($0) }
    }
}

// MARK: - File Utilities

extension String {
    fileprivate func appendLineToURL(_ fileURL: URL) throws {
        try (self + "\n").appendToURL(fileURL)
    }

    fileprivate func appendToURL(_ fileURL: URL) throws {
        if let data = data(using: .utf8) {
            try data.appendToURL(fileURL)
        }
    }
}

extension Data {
    fileprivate func appendToURL(_ fileURL: URL) throws {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(self)
        } else {
            try write(to: fileURL, options: .atomic)
        }
    }
}

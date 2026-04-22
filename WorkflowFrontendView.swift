import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorkflowFrontendManifest: Codable, Equatable {
    let version: Int
    let id: String
    let name: String
    let framework: String?
    let entry: String
    let apiBasePath: String?
    let defaultPath: String?
}

struct WorkflowFrontendDescriptor: Equatable {
    let manifest: WorkflowFrontendManifest
    let manifestPath: String
    let frontendDirectoryPath: String
    let serverScriptPath: String

    var routePath: String {
        let raw = manifest.defaultPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/"
        guard !raw.isEmpty else { return "/" }
        return raw.hasPrefix("/") ? raw : "/\(raw)"
    }
}

@MainActor
enum WorkflowFrontendResolver {
    static func loadDescriptor(
        for workflow: Workflow,
        smithers: SmithersClient
    ) throws -> WorkflowFrontendDescriptor? {
        guard let workflowPath = workflow.filePath else { return nil }

        let absoluteWorkflowPath: String
        if workflowPath.hasPrefix("/") {
            absoluteWorkflowPath = workflowPath
        } else {
            absoluteWorkflowPath = try smithers.localSmithersFilePath(workflowPath)
        }

        let frontendDirectoryURL = URL(fileURLWithPath: absoluteWorkflowPath)
            .deletingPathExtension()
            .appendingPathExtension("frontend")
        let manifestURL = frontendDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(WorkflowFrontendManifest.self, from: data)
        let serverScriptURL = frontendDirectoryURL.appendingPathComponent("server.ts", isDirectory: false)
        guard FileManager.default.fileExists(atPath: serverScriptURL.path) else {
            throw NSError(
                domain: "WorkflowFrontendResolver",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Frontend manifest exists but server.ts is missing."]
            )
        }

        return WorkflowFrontendDescriptor(
            manifest: manifest,
            manifestPath: manifestURL.path,
            frontendDirectoryPath: frontendDirectoryURL.path,
            serverScriptPath: serverScriptURL.path
        )
    }
}

@MainActor
final class WorkflowFrontendServerController: ObservableObject {
    enum Phase: Equatable {
        case starting
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting

    private let descriptor: WorkflowFrontendDescriptor
    private let workingDirectory: String

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var collectedErrors: [String] = []
    private var didBecomeReady = false

    init(descriptor: WorkflowFrontendDescriptor, workingDirectory: String) {
        self.descriptor = descriptor
        self.workingDirectory = workingDirectory
    }

    func start() {
        stop()
        phase = .starting
        didBecomeReady = false
        stdoutBuffer = Data()
        stderrBuffer = Data()
        collectedErrors = []

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bun", descriptor.serverScriptPath, "--port", "0"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data, isError: false)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data, isError: true)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: terminated.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            phase = .failed(error.localizedDescription)
            cleanupFileHandles()
        }
    }

    func restart() {
        start()
    }

    func stop() {
        cleanupFileHandles()
        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }
    }

    private func consume(_ data: Data, isError: Bool) {
        if isError {
            stderrBuffer.append(data)
            flushLines(from: &stderrBuffer, isError: true)
        } else {
            stdoutBuffer.append(data)
            flushLines(from: &stdoutBuffer, isError: false)
        }
    }

    private func flushLines(from buffer: inout Data, isError: Bool) {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            handleLine(line, isError: isError)
        }
    }

    private func handleLine(_ line: String, isError: Bool) {
        if isError {
            collectedErrors.append(line)
            return
        }

        struct ReadyEvent: Decodable {
            let type: String
            let port: Int
        }

        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(ReadyEvent.self, from: data),
              event.type == "ready"
        else {
            return
        }

        didBecomeReady = true
        let url = URL(string: "http://127.0.0.1:\(event.port)\(descriptor.routePath)")!
        phase = .ready(url)
    }

    private func handleTermination(status: Int32) {
        cleanupFileHandles()
        process = nil

        guard !didBecomeReady else { return }

        let details = collectedErrors.joined(separator: "\n")
        if !details.isEmpty {
            phase = .failed(details)
        } else if status != 0 {
            phase = .failed("Frontend server exited with status \(status).")
        } else {
            phase = .failed("Frontend server exited before it became ready.")
        }
    }

    private func cleanupFileHandles() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }
}

struct WorkflowFrontendView: View {
    let workflow: Workflow
    let descriptor: WorkflowFrontendDescriptor
    let workingDirectory: String

    @StateObject private var controller: WorkflowFrontendServerController

    init(
        workflow: Workflow,
        descriptor: WorkflowFrontendDescriptor,
        workingDirectory: String
    ) {
        self.workflow = workflow
        self.descriptor = descriptor
        self.workingDirectory = workingDirectory
        _controller = StateObject(
            wrappedValue: WorkflowFrontendServerController(
                descriptor: descriptor,
                workingDirectory: workingDirectory
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.base)
        .onAppear {
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(descriptor.manifest.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(descriptor.manifest.framework ?? "html") frontend served from \(descriptor.frontendDirectoryPath)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            switch controller.phase {
            case .starting:
                Label("Starting", systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.warning)
            case .ready:
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.success)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.danger)
            }

            Button("Restart") {
                controller.restart()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.inputBg)
            .cornerRadius(6)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .border(Theme.border, edges: [.bottom])
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Launching workflow frontend...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Text(descriptor.serverScriptPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Theme.danger)
                Text("Unable to start workflow frontend")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry") {
                    controller.restart()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.accent)
                .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let url):
            ZStack(alignment: .bottomTrailing) {
                BrowserWebViewRepresentable(
                    surfaceId: "workflow-frontend-\(workflow.id)-\(descriptor.manifest.id)",
                    urlString: url.absoluteString,
                    onTitleChange: { _ in },
                    onURLChange: { _ in },
                    onFocus: {}
                )

                Button("Open In Browser") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.surface2.opacity(0.94))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .padding(10)
            }
        }
    }
}

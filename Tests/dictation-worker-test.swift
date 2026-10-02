import Foundation
import Synchronization

@main
struct DictationWorkerTest {
    @MainActor private final class Readiness { var count = 0; var workers = 0 }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--fixture") { try fixture(); return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let worker = try DictationWorker(executable: executable, arguments: ["--fixture"])
        let readiness = Readiness()
        for model in DictationModel.allCases {
            let samples = [Float](repeating: 0.125, count: 16_000)
            let request = DictationWire.Request(id: UUID(), model: model,
                directory: URL(fileURLWithPath: "/tmp/models"), sampleCount: samples.count,
                language: nil)
            let text = try await worker.transcribe(samples, request: request) { readiness.count += 1 }
            guard text == model.rawValue else { fatalError("Model response did not match its request") }
        }
        guard readiness.count == DictationModel.allCases.count else { fatalError("Missing readiness event") }
        await worker.stop()
        await worker.stop()

        for behavior in ["crash", "wait"] {
            let worker = try DictationWorker(executable: executable, arguments: ["--fixture", behavior])
            let samples = [Float](repeating: 0, count: 1_000_000)
            let request = DictationWire.Request(id: UUID(), model: .ultra,
                directory: URL(fileURLWithPath: "/tmp/models"), sampleCount: samples.count,
                language: nil)
            let task = Task { try await worker.transcribe(samples, request: request, onReady: {}) }
            if behavior == "wait" {
                try await Task.sleep(for: .milliseconds(100))
                task.cancel()
            }
            do {
                _ = try await task.value
                fatalError("Unexpected successful transcription")
            } catch {}
            await worker.stop()
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for model in DictationModel.allCases {
            let directory = root.appending(path: model.folderName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in model.requiredFiles { try Data([0]).write(to: directory.appending(path: name)) }
        }
        let store = DictationModelStore(idleRelease: .never, root: root) {
            readiness.workers += 1
            return try DictationWorker(executable: executable, arguments: ["--fixture"])
        }
        guard store.installedModels.count == DictationModel.allCases.count,
            try await store.installedSize(.redux) == Int64(DictationModel.redux.requiredFiles.count) else {
            fatalError("Installed model metadata is incorrect")
        }
        let cancelled = Task { try await store.transcribe([0], model: .redux) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled transcription started")
        } catch is CancellationError {}
        guard readiness.workers == 0, store.loadedModel == nil, !store.transcribing else {
            fatalError("Cancelled transcription launched a helper")
        }
        for model in [DictationModel.redux, .redux, .ultra] {
            let text = try await store.transcribe([0], model: model)
            guard text == model.rawValue, store.loadedModel == model, !store.transcribing else {
                fatalError("Model store failed to finish a request")
            }
        }
        guard readiness.workers == 2 else { fatalError("Worker reuse or model-switch cleanup failed") }
        try await store.delete(.ultra)
        guard store.loadedModel == nil, store.removing == nil, !store.isInstalled(.ultra),
            !FileManager.default.fileExists(atPath: root.appending(path: DictationModel.ultra.folderName).path) else {
            fatalError("Model removal retained files or a loaded helper")
        }
        await store.stop()
        try await testDownload(root: root.appending(path: "downloads"))
        print("Dictation worker reuse, switching, removal, cancellation and broken pipes passed")
    }

    private static func testDownload(root: URL) async throws {
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let models: [DictationModel] = [.redux, .qwenSmall]
        let files = models.reduce(into: Set<String>()) { $0.formUnion($1.requiredFiles) }.sorted().map {
            $0.hasSuffix(".mlmodelc") ? $0 + "/weights.bin" : $0
        }
        guard let paths = String(bytes: try JSONEncoder().encode(files), encoding: .utf8) else {
            fatalError("Invalid download fixture paths")
        }
        server.arguments = ["node", "-e", """
            const http = require('http'), crypto = require('crypto');
            const content = Buffer.alloc(524288, 65);
            const files = JSON.parse(process.argv[1]).map(path => ({path, type: 'file', size: content.length,
                lfs: {oid: crypto.createHash('sha256').update(content).digest('hex')}}));
            const server = http.createServer((request, response) => {
                if (request.url.includes('/tree/')) {
                    response.end(JSON.stringify(files));
                    return;
                }
                response.writeHead(200, {'Content-Length': content.length});
                let offset = 0;
                const timer = setInterval(() => {
                    response.write(content.subarray(offset, offset + 65536));
                    offset += 65536;
                    if (offset >= content.length) { clearInterval(timer); response.end(); }
                }, 40);
                response.on('close', () => clearInterval(timer));
            });
            server.listen(0, '127.0.0.1', () => console.log(server.address().port));
            """, paths]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        let exit = try server.runObservingExit()
        defer { if server.isRunning { server.terminate() }; exit.wait() }
        try output.fileHandleForWriting.close()
        var data = Data()
        while data.last != 10, data.count < 8 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                fatalError("Download fixture exited before starting")
            }
            data.append(byte)
        }
        guard let text = String(bytes: data, encoding: .utf8),
            let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let base = URL(string: "http://127.0.0.1:\(port)/") else { fatalError("Download fixture did not start") }
        let events = Mutex<[(received: Int64, total: Int64)]>([])
        let destination = root.appending(path: DictationModel.redux.folderName)
        let cancelled = Task.detached {
            try await DictationModelDownloader.download(.redux, destination: destination, baseURL: base) { received, total in
                events.withLock { $0.append((received, total)) }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !events.withLock({ $0.contains { $0.received > 0 && $0.received < 524288 } }),
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            fatalError("Cancelled download installed a model")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {}
        guard !FileManager.default.fileExists(atPath: destination.path),
            try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            fatalError("Cancellation retained a partial model")
        }
        for model in models {
            events.withLock { $0.removeAll() }
            try await DictationModelDownloader.download(model, destination: root.appending(path: model.folderName),
                baseURL: base) { received, total in events.withLock { $0.append((received, total)) } }
            let progress = events.withLock { $0 }
            let expected = Int64(model.requiredFiles.count) * 524288
            guard progress.first?.received == 0, progress.last?.received == expected,
                progress.allSatisfy({ $0.total == expected && $0.received <= expected }),
                zip(progress, progress.dropFirst()).allSatisfy({ $0.received <= $1.received }),
                progress.contains(where: { $0.received > 0 && $0.received < 524288 }) else {
                fatalError("Combined download progress is incorrect")
            }
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == models.map(\.folderName).sorted() else {
            fatalError("Atomic installation retained staging files")
        }
    }

    private static func fixture() throws {
        while let request = try DictationWire.read(DictationWire.Request.self, from: .standardInput) {
            try DictationWire.write(DictationWire.Response(id: request.id, status: .ready), to: .standardOutput)
            if CommandLine.arguments.contains("crash") { exit(1) }
            _ = try DictationWire.readExactly(request.sampleCount * 4, from: .standardInput)
            if CommandLine.arguments.contains("wait") { Thread.sleep(forTimeInterval: 10) }
            try DictationWire.write(DictationWire.Response(id: request.id, status: .result,
                text: request.model.rawValue), to: .standardOutput)
        }
    }
}

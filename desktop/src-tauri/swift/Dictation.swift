// Dictation, on this machine, with no key and no model of ours.
//
// macOS 26 introduced `SpeechAnalyzer` and `SpeechTranscriber`: long-form,
// on-device speech to text, with the model assets managed by the OS and
// shared between apps. Nothing is downloaded by Patchwork, nothing is sent
// anywhere, and a five minute ramble is a supported case rather than a
// workaround. The older `SFSpeechRecognizer` caps out around a minute and is
// four times less accurate, so it is not a fallback worth having.
//
// It is a Swift-only API, so this file exists: a C interface the Rust side
// links against. The same file compiles for iOS when there is an iOS app,
// because the API is `@available(anyAppleOS 26)`.

import AVFoundation
import Foundation
import Speech

/// What the caller is told, and when.
///
/// `volatile` text is the tail the recogniser is still revising and replaces
/// whatever it sent last; `final` text is settled and is appended. Keeping
/// the distinction here means the UI can show words as they are spoken
/// without inventing its own idea of which ones are safe.
private let kindVolatile: Int32 = 0
private let kindFinal: Int32 = 1
private let kindError: Int32 = 2
private let kindStopped: Int32 = 3

public typealias Emit = @convention(c) (Int32, UnsafePointer<CChar>) -> Void

private func send(_ emit: Emit, _ kind: Int32, _ text: String) {
    text.withCString { emit(kind, $0) }
}

@available(macOS 26.0, iOS 26.0, *)
private final class Session: @unchecked Sendable {
    static var current: Session?

    private let engine = AVAudioEngine()
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let stream: AsyncStream<AnalyzerInput>
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private var reader: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    init(locale: Locale) {
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// The locale's model, downloaded by the OS the first time it is asked
    /// for. Most machines already have their own language installed.
    private func installIfNeeded() async throws {
        guard
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
        else { return }
        try await request.downloadAndInstall()
    }

    func start(emit: @escaping Emit) async throws {
        try await installIfNeeded()
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])

        reader = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if text.isEmpty { continue }
                    send(emit, result.isFinal ? kindFinal : kindVolatile, text)
                }
            } catch {
                send(emit, kindError, "\(error)")
            }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.convert(buffer) else { return }
            self.feed.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
    }

    /// The microphone's format is whatever the hardware feels like; the
    /// analyzer asks for its own. One converter, made on the first buffer.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = analyzerFormat else { return nil }
        if buffer.format == target { return buffer }
        if converter == nil || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    func stop(emit: @escaping Emit) async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            send(emit, kindError, "\(error)")
        }
        _ = await reader?.value
        send(emit, kindStopped, "")
    }
}

/// Whether this machine can dictate at all: the API exists, and the locale
/// has a model that is installed or installable.
@_cdecl("pw_dictation_supported")
public func pw_dictation_supported() -> Int32 {
    guard #available(macOS 26.0, iOS 26.0, *) else { return 0 }
    let semaphore = DispatchSemaphore(value: 0)
    var supported: Int32 = 0
    Task {
        let locales = await SpeechTranscriber.supportedLocales
        supported = locales.isEmpty ? 0 : 1
        semaphore.signal()
    }
    semaphore.wait()
    return supported
}

/// Start listening. Text arrives on `emit` until `pw_dictation_stop`.
@_cdecl("pw_dictation_start")
public func pw_dictation_start(
    _ localeId: UnsafePointer<CChar>,
    _ emit: @escaping Emit
) -> Int32 {
    guard #available(macOS 26.0, iOS 26.0, *) else {
        send(emit, kindError, "dictation needs macOS 26 or newer")
        return 0
    }
    guard Session.current == nil else { return 1 }

    let identifier = String(cString: localeId)
    let locale = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    let session = Session(locale: locale)
    Session.current = session

    Task {
        // The prompt names Patchwork, and only appears the first time.
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            Session.current = nil
            send(emit, kindError, "Patchwork is not allowed to use the microphone")
            return
        }
        do {
            try await session.start(emit: emit)
        } catch {
            Session.current = nil
            send(emit, kindError, "\(error)")
        }
    }
    return 1
}

@_cdecl("pw_dictation_stop")
public func pw_dictation_stop(_ emit: @escaping Emit) {
    guard #available(macOS 26.0, iOS 26.0, *) else { return }
    guard let session = Session.current else {
        send(emit, kindStopped, "")
        return
    }
    Session.current = nil
    Task { await session.stop(emit: emit) }
}

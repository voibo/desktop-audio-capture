import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

class AudioCapture: NSObject, @unchecked Sendable {
    private let logger = Logger()

    private(set) var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private let audioSampleBufferQueue = DispatchQueue(label: "jp.spiralmind.audio-capture.AudioSampleBufferQueue")  // TODO: ラベルを外部から指定できるようにする

    private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?

    public func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
            self.continuation = continuation
            let streamOutput = CaptureStreamOutput(continuation: continuation)
            self.streamOutput = streamOutput
            streamOutput.pcmBufferHandler = { continuation.yield($0) }

            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)

                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
                stream?.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // SharedCaptureTargetを使用するように修正
    public func startCapture(
        target: SharedCaptureTarget,
        configuration: SCStreamConfiguration
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
            Task {
                do {
                    // CaptureTargetConverterを使用
                    let filter = try await CaptureTargetConverter.createContentFilter(from: target)
                    
                    // 既存のメソッドを呼び出す
                    for try await buffer in startCapture(configuration: configuration, filter: filter) {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func stopCapture() async {
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }

    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }
}

private class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?

    init(continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .audio:
            handleAudio(for: sampleBuffer)
        default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
    }

    private func handleAudio(for buffer: CMSampleBuffer) -> Void? {
        try? buffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let description = buffer.formatDescription?.audioStreamBasicDescription,
                let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame),
                let samples = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            pcmBufferHandler?(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish(throwing: error)
    }
}

import Foundation
import Vision
import CoreImage
import AppKit
import Combine

@MainActor
class OCRManager: ObservableObject {
    @Published var isProcessing = false
    @Published var lastRecognizedText = ""
    @Published var recognizedRegions: [TextRegion] = []

    /// Whether to prefer PiKVM's server-side Tesseract OCR (`GET /api/streamer/snapshot?ocr=true`)
    /// over local Apple Vision OCR. When false, Apple Vision runs first and falls back to server OCR
    /// if no local frame is available.
    @Published var preferRemoteServerOCR: Bool {
        didSet { UserDefaults.standard.set(preferRemoteServerOCR, forKey: Self.preferRemoteOCRDefaultsKey) }
    }
    @Published var remoteOcrLanguage: String {
        didSet { UserDefaults.standard.set(remoteOcrLanguage, forKey: Self.remoteOcrLangDefaultsKey) }
    }
    @Published var availableRemoteOcrLanguages: [String] = ["eng"]
    @Published var remoteOcrEnabledOnDevice: Bool = false

    private static let preferRemoteOCRDefaultsKey = "overlook.ocr.preferRemoteServer"
    private static let remoteOcrLangDefaultsKey = "overlook.ocr.remoteLanguage"

    nonisolated(unsafe) private var textRecognitionRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var textObservationRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var ocrQueue = DispatchQueue(label: "com.overlook.ocr", qos: .userInitiated)

    init() {
        let defaults = UserDefaults.standard
        preferRemoteServerOCR = defaults.bool(forKey: Self.preferRemoteOCRDefaultsKey)
        remoteOcrLanguage = defaults.string(forKey: Self.remoteOcrLangDefaultsKey) ?? "eng"
        setupOCRRequests()
    }

    func refreshRemoteOcrState(using client: GLKVMClient?) async {
        guard let client else {
            applyRemoteOcrState(nil)
            return
        }
        let state = try? await client.getStreamerOcrState()
        applyRemoteOcrState(state)
    }

    func applyRemoteOcrState(_ state: GLKVMStreamerOcrState?) {
        guard let state else {
            remoteOcrEnabledOnDevice = false
            availableRemoteOcrLanguages = ["eng"]
            return
        }
        remoteOcrEnabledOnDevice = state.ocr.enabled
        let langs = state.ocr.langs?.available ?? ["eng"]
        availableRemoteOcrLanguages = langs.isEmpty ? ["eng"] : langs
        if let defLang = state.ocr.langs?.default.first, !langs.contains(remoteOcrLanguage) {
            remoteOcrLanguage = defLang
        }
    }

    private func setupOCRRequests() {
        // Setup text recognition request for Live Text-style OCR
        textRecognitionRequest = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleTextRecognition(request: request, error: error)
            }
        }

        // Configure for high accuracy
        textRecognitionRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textRecognitionRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textRecognitionRequest?.automaticallyDetectsLanguage = true

        // Setup text observation request for real-time text detection
        textObservationRequest = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleTextObservation(request: request, error: error)
            }
        }

        textObservationRequest?.recognitionLevel = .fast
        textObservationRequest?.usesLanguageCorrection = false
        textObservationRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textObservationRequest?.automaticallyDetectsLanguage = true
    }

    func recognizeText(
        at point: CGPoint,
        in pixelBuffer: CVPixelBuffer?,
        client: GLKVMClient? = nil,
        videoSize: CGSize? = nil
    ) async throws -> String {
        if preferRemoteServerOCR || pixelBuffer == nil, let client {
            if let remoteText = try? await performRemotePointOCR(point: point, client: client, videoSize: videoSize),
               !remoteText.isEmpty {
                lastRecognizedText = remoteText
                return remoteText
            }
        }

        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performTextRecognition(at: point, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func performRemotePointOCR(point: CGPoint, client: GLKVMClient, videoSize: CGSize?) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let size = videoSize ?? CGSize(width: 1920, height: 1080)
        let boxSize: CGFloat = min(600, min(size.width, size.height))
        let centerX = max(0, min(1, point.x)) * size.width
        // `point.y` is in Vision coordinates (bottom-left); convert to top-left for PiKVM API
        let topLeftY = (1.0 - max(0, min(1, point.y))) * size.height

        let left = Int(max(0, min(centerX - boxSize / 2, size.width - boxSize)))
        let top = Int(max(0, min(topLeftY - boxSize / 2, size.height - boxSize)))
        let width = Int(boxSize)
        let height = Int(boxSize)

        let raw = try await client.performStreamerOCR(
            langs: [remoteOcrLanguage],
            left: left,
            top: top,
            right: width,
            bottom: height
        )
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func performTextRecognition(at point: CGPoint, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        // Create a region of interest around the click point
        let roi = createRegionOfInterest(around: point, in: pixelBuffer)
        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: roi)

        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])

        Task { @MainActor in
            isProcessing = true
        }

        do {
            try handler.perform([request])

            // Get the recognized text from the request
            guard let observations = request.results else {
                completion(.failure(OCRError.noTextFound))
                return
            }

            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")

            Task { @MainActor in
                lastRecognizedText = recognizedText
                isProcessing = false
            }

            if recognizedText.isEmpty {
                completion(.failure(OCRError.noTextFound))
            } else {
                completion(.success(recognizedText))
            }

        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }

    func detectTextRegions(in pixelBuffer: CVPixelBuffer?) async throws -> [TextRegion] {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performTextDetection(in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    nonisolated private func performTextDetection(in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<[TextRegion], Error>) -> Void) {
        guard let request = textObservationRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])

            guard let observations = request.results else {
                completion(.success([]))
                return
            }

            let textRegions = observations.compactMap { observation -> TextRegion? in
                guard let candidate = observation.topCandidates(1).first else { return nil }

                return TextRegion(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }

            Task { @MainActor in
                recognizedRegions = textRegions
            }

            completion(.success(textRegions))

        } catch {
            completion(.failure(error))
        }
    }

    nonisolated private func createRegionOfInterest(around point: CGPoint, in pixelBuffer: CVPixelBuffer) -> CGRect {
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))

        let minAxis = min(bufferSize.width, bufferSize.height)
        let regionSize: CGFloat = min(800, minAxis)

        let centerX = clampedX * bufferSize.width
        let centerY = clampedY * bufferSize.height

        let rawX = centerX - regionSize / 2
        let rawY = centerY - regionSize / 2

        let x = max(0, min(rawX, bufferSize.width - regionSize))
        let y = max(0, min(rawY, bufferSize.height - regionSize))

        let regionRect = CGRect(x: x, y: y, width: regionSize, height: regionSize)

        return regionRect
    }

    nonisolated private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = ciImage.extent.integral
        let requested = rect.integral
        let clipped = requested.intersection(sourceExtent)

        if clipped.isEmpty {
            return pixelBuffer
        }

        let croppedImage = ciImage
            .cropped(to: clipped)
            .transformed(by: CGAffineTransform(translationX: -clipped.origin.x, y: -clipped.origin.y))

        var croppedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clipped.width),
            Int(clipped.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &croppedPixelBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = croppedPixelBuffer else {
            return pixelBuffer
        }

        let context = CIContext()
        context.render(croppedImage, to: outputBuffer)

        return outputBuffer
    }

    private func handleTextRecognition(request: VNRequest, error: Error?) {
        if let error = error {
            clog.warning(.stream, "Text recognition error: \(error.localizedDescription)")
            return
        }

        guard let request = request as? VNRecognizeTextRequest,
              let observations = request.results else {
            return
        }

        let recognizedText = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }.joined(separator: "\n")

        Task { @MainActor in
            lastRecognizedText = recognizedText
            isProcessing = false
        }
    }

    private func handleTextObservation(request: VNRequest, error: Error?) {
        if let error = error {
            clog.warning(.stream, "Text observation error: \(error.localizedDescription)")
            return
        }

        guard let request = request as? VNRecognizeTextRequest,
              let observations = request.results else {
            return
        }

        let regions = observations.compactMap { observation -> TextRegion? in
            guard let candidate = observation.topCandidates(1).first else { return nil }

            return TextRegion(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }

        Task { @MainActor in
            recognizedRegions = regions
        }
    }

    // MARK: - Advanced OCR Features

    func recognizeTextInRegion(
        _ region: CGRect,
        topLeftNormalizedRect: CGRect? = nil,
        in pixelBuffer: CVPixelBuffer?,
        client: GLKVMClient? = nil,
        videoSize: CGSize? = nil
    ) async throws -> String {
        if preferRemoteServerOCR || pixelBuffer == nil, let client {
            let norm = topLeftNormalizedRect ?? CGRect(
                x: region.origin.x,
                y: 1.0 - region.maxY,
                width: region.width,
                height: region.height
            )
            if let remoteText = try? await performRemoteRegionOCR(topLeftNormalizedRect: norm, client: client, videoSize: videoSize),
               !remoteText.isEmpty {
                lastRecognizedText = remoteText
                return remoteText
            }
        }

        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performRegionTextRecognition(region: region, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func performRemoteRegionOCR(
        topLeftNormalizedRect: CGRect,
        client: GLKVMClient,
        videoSize: CGSize?
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let size = videoSize ?? CGSize(width: 1920, height: 1080)
        let left = Int(max(0, topLeftNormalizedRect.minX * size.width))
        let top = Int(max(0, topLeftNormalizedRect.minY * size.height))
        let width = Int(max(16, topLeftNormalizedRect.width * size.width))
        let height = Int(max(16, topLeftNormalizedRect.height * size.height))

        let raw = try await client.performStreamerOCR(
            langs: [remoteOcrLanguage],
            left: left,
            top: top,
            right: width,
            bottom: height
        )
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func performRegionTextRecognition(region: CGRect, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let normalizedRegion = CGRect(
            x: region.origin.x * bufferSize.width,
            y: region.origin.y * bufferSize.height,
            width: region.size.width * bufferSize.width,
            height: region.size.height * bufferSize.height
        )

        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: normalizedRegion)
        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])

        Task { @MainActor in
            isProcessing = true
        }

        do {
            try handler.perform([request])

            guard let observations = request.results else {
                completion(.failure(OCRError.noTextFound))
                return
            }

            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")

            Task { @MainActor in
                lastRecognizedText = recognizedText
                isProcessing = false
            }

            completion(.success(recognizedText))

        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }

    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func getTextAtLocation(_ point: CGPoint, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        // First detect all text regions
        let regions = try await detectTextRegions(in: pixelBuffer)

        // Find the region that contains the click point
        for region in regions {
            if region.boundingBox.contains(point) {
                return region.text
            }
        }

        // If no region contains the point, perform OCR in a small area around the point
        let smallRegion = CGRect(
            x: max(0, point.x - 0.05),
            y: max(0, point.y - 0.05),
            width: min(0.1, 1.0),
            height: min(0.1, 1.0)
        )

        return try await recognizeTextInRegion(smallRegion, in: pixelBuffer)
    }
}

// MARK: - Supporting Types
struct TextRegion: Identifiable, Codable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    var displayText: String {
        return confidence > 0.5 ? text : "[\(text)]"
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

enum OCRError: Error, LocalizedError {
    case noVideoFrame
    case requestNotInitialized
    case noTextFound
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoFrame:
            return "No video frame available for OCR"
        case .requestNotInitialized:
            return "OCR request not properly initialized"
        case .noTextFound:
            return "No text found in the specified region"
        case .processingFailed:
            return "OCR processing failed"
        }
    }
}

// MARK: - OCR Configuration
extension OCRManager {
    func updateRecognitionLanguages(_ languages: [String]) {
        textRecognitionRequest?.recognitionLanguages = languages
        textObservationRequest?.recognitionLanguages = languages
    }

    func setRecognitionLevel(_ level: VNRequestTextRecognitionLevel) {
        textRecognitionRequest?.recognitionLevel = level
    }

    func enableLanguageCorrection(_ enabled: Bool) {
        textRecognitionRequest?.usesLanguageCorrection = enabled
    }

    func setMinimumTextHeight(_ height: Float) {
        textRecognitionRequest?.minimumTextHeight = height
        textObservationRequest?.minimumTextHeight = height
    }
}

// MARK: - Performance Optimization
extension OCRManager {
    func optimizeForRealTime() {
        textRecognitionRequest?.recognitionLevel = .fast
        textObservationRequest?.recognitionLevel = .fast
        textRecognitionRequest?.usesLanguageCorrection = false
        textObservationRequest?.usesLanguageCorrection = false
    }

    func optimizeForAccuracy() {
        textRecognitionRequest?.recognitionLevel = .accurate
        textObservationRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textObservationRequest?.usesLanguageCorrection = true
    }
}

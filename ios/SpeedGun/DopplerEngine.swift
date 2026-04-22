import Foundation
import AVFoundation
import Accelerate
import Combine

final class DopplerEngine: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case both, listen, emit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both:   return "Both (emit + listen)"
            case .listen: return "Listen only"
            case .emit:   return "Emit only"
            }
        }
    }

    // MARK: UI-bound state (main thread)
    @Published var speedMph: Double = 0
    @Published var direction: String = ""
    @Published var statusMessage: String = "Tap Start"
    @Published var running: Bool = false
    @Published var carrierHz: Double = 18_000
    @Published var mode: Mode = .both

    // MARK: DSP config (match the web tester: simple threshold, Blackman window)
    private let fftSize       = 16384
    private let speedOfSound  = 343.0
    private let mpsToMph      = 2.23694
    private let carrierBW     = 500.0   // search ±Hz around target carrier
    private let carrierNotch  = 30.0    // ignore ±Hz of bins around carrier
    private let targetBW      = 5000.0  // ±Hz of sideband to search
    private let minCarrierDb: Float = -80
    private let minPeakDb:    Float = -95
    private let emaAlpha      = 0.35

    // MARK: Audio nodes
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sampleRate: Double = 48_000

    // Carrier frozen at start() so the DSP thread reads a stable value.
    private var frozenCarrier: Double = 18_000

    // MARK: DSP state (processQueue only)
    private let processQueue = DispatchQueue(label: "speedgun.process", qos: .userInteractive)
    private var sampleBuffer: [Float] = []
    private var window: [Float] = []
    private var fftSetup: FFTSetup?
    private var smoothedSpeed: Double = 0

    init() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_blkman_window(&window, vDSP_Length(fftSize), 0)
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Public controls

    func start() {
        guard !running else { return }
        DispatchQueue.main.async { self.statusMessage = "Starting…" }
        do {
            try configureSession()
            try setupNodes()
            engine.prepare()
            try engine.start()
            DispatchQueue.main.async {
                self.running = true
                self.statusMessage = "Running — move something past the phone"
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
            teardown()
        }
    }

    func stop() {
        teardown()
        DispatchQueue.main.async {
            self.running = false
            self.speedMph = 0
            self.direction = ""
            self.statusMessage = "Stopped"
        }
    }

    // MARK: - Setup

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        if mode == .emit {
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.mixWithOthers])
        } else {
            // .defaultToSpeaker is the whole reason we're bothering with native.
            // It forces output to the loud bottom speaker while recording,
            // instead of the quiet earpiece that Safari gets stuck with.
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.defaultToSpeaker, .mixWithOthers])
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        sampleRate = session.sampleRate
    }

    private func setupNodes() throws {
        frozenCarrier = carrierHz

        if mode != .listen {
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            // Capture these by value into the closure; do NOT touch self from
            // the real-time render callback. phase is captured by reference
            // (closure escape) and only mutated by this closure, so it's
            // single-threaded relative to itself.
            let inc = 2.0 * .pi * carrierHz / outFormat.sampleRate
            var phase: Double = 0
            let src = AVAudioSourceNode(format: outFormat) { _, _, frameCount, ablPtr in
                let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                for buffer in abl {
                    guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<Int(frameCount) {
                        p[i] = Float(sin(phase)) * 0.95
                        phase += inc
                        if phase > 2 * .pi { phase -= 2 * .pi }
                    }
                }
                return noErr
            }
            sourceNode = src
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: outFormat)
        }

        if mode != .emit {
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                self?.ingest(buffer)
            }
        }
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if let s = sourceNode {
            engine.detach(s)
            sourceNode = nil
        }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false,
            options: [.notifyOthersOnDeactivation])
        processQueue.async {
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.smoothedSpeed = 0
        }
    }

    // MARK: - Ingest / process

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        processQueue.async { [weak self] in
            self?.consume(samples)
        }
    }

    private func consume(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)
        while sampleBuffer.count >= fftSize {
            let frame = Array(sampleBuffer.prefix(fftSize))
            sampleBuffer.removeFirst(fftSize / 2)    // 50% overlap
            analyze(frame)
        }
    }

    private func analyze(_ frame: [Float]) {
        guard let setup = fftSetup else { return }
        let half = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)))

        // 1. Window the frame.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // 2. Real FFT (packed real-input: N real samples -> N/2 complex bins).
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!,
                                            imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Normalize by N (vDSP_fft_zrip leaves raw sums).
        var invN = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &invN, &magnitudes, 1, vDSP_Length(half))

        // 3. Peak logic — same as the web tester.
        let binHz = sampleRate / Double(fftSize)
        let cSearchLo = max(0, Int((frozenCarrier - carrierBW) / binHz))
        let cSearchHi = min(half - 1, Int((frozenCarrier + carrierBW) / binHz))
        var carrierIdx = cSearchLo
        var carrierMag: Float = 0
        for i in cSearchLo...cSearchHi where magnitudes[i] > carrierMag {
            carrierMag = magnitudes[i]; carrierIdx = i
        }
        let cDb = 20 * log10(carrierMag + 1e-20)

        guard cDb >= minCarrierDb else {
            DispatchQueue.main.async {
                self.speedMph = 0
                self.direction = ""
                self.statusMessage = "Waiting for carrier…"
            }
            return
        }

        let cHz = Double(carrierIdx) * binHz
        let notch = max(1, Int(carrierNotch / binHz))
        let uLo = carrierIdx + notch
        let uHi = min(half - 1, Int((cHz + targetBW) / binHz))
        let lHi = carrierIdx - notch
        let lLo = max(0, Int((cHz - targetBW) / binHz))

        var peakIdx = -1
        var peakMag: Float = 0
        if uLo <= uHi {
            for i in uLo...uHi where magnitudes[i] > peakMag {
                peakMag = magnitudes[i]; peakIdx = i
            }
        }
        if lLo <= lHi {
            for i in lLo...lHi where magnitudes[i] > peakMag {
                peakMag = magnitudes[i]; peakIdx = i
            }
        }
        let pDb = 20 * log10(peakMag + 1e-20)

        if peakIdx >= 0 && pDb >= minPeakDb {
            let peakHz = Double(peakIdx) * binHz
            let v = speedOfSound * (peakHz - cHz) / (peakHz + cHz)
            smoothedSpeed = emaAlpha * v + (1 - emaAlpha) * smoothedSpeed
        } else {
            smoothedSpeed *= 0.85
        }

        let displayMph = abs(smoothedSpeed) * mpsToMph
        let dir = smoothedSpeed > 0.2 ? "toward"
                : smoothedSpeed < -0.2 ? "away" : ""

        DispatchQueue.main.async {
            self.speedMph = displayMph < 0.05 ? 0 : displayMph
            self.direction = dir
            self.statusMessage = "Running"
        }
    }
}

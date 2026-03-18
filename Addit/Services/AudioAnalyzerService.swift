import Foundation
import AVFoundation
import Accelerate

@Observable
final class AudioAnalyzerService {
    var bands: [Float] = Array(repeating: 0, count: 16)

    @ObservationIgnored private weak var playerService: AudioPlayerService?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private let smoothing: Float = 0.7

    // FFT setup
    @ObservationIgnored private var fftSetup: vDSP_DFT_Setup?
    @ObservationIgnored private let fftSize = 4096

    init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func configure(playerService: AudioPlayerService) {
        self.playerService = playerService
    }

    func start() {
        guard !isActive, let playerService else { return }
        isActive = true

        let mixer = playerService.engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
    }

    func stop() {
        guard isActive, let playerService else { return }
        isActive = false

        playerService.engine.mainMixerNode.removeTap(onBus: 0)

        DispatchQueue.main.async { [weak self] in
            self?.bands = Array(repeating: 0, count: 16)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let setup = fftSetup,
              let channelData = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return }

        // Copy channel data into a safe array
        var samples = [Float](repeating: 0, count: fftSize)
        memcpy(&samples, channelData, fftSize * MemoryLayout<Float>.size)

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Prepare split complex for FFT
        var realInput = [Float](repeating: 0, count: fftSize)
        var imagInput = [Float](repeating: 0, count: fftSize)
        var realOutput = [Float](repeating: 0, count: fftSize)
        var imagOutput = [Float](repeating: 0, count: fftSize)

        realInput = windowed

        // Execute FFT
        vDSP_DFT_Execute(setup, &realInput, &imagInput, &realOutput, &imagOutput)

        // Calculate magnitudes (first half only — symmetric)
        let halfSize = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: halfSize)
        for i in 0..<halfSize {
            magnitudes[i] = sqrt(realOutput[i] * realOutput[i] + imagOutput[i] * imagOutput[i])
        }

        // Normalize to dBFS: divide by fftSize/2 so a full-scale sine = 1.0 (0 dBFS)
        let normFactor = 2.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, [normFactor], &magnitudes, 1, vDSP_Length(halfSize))

        // Convert to dB
        var one: Float = 1.0
        vDSP_vdbcon(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(halfSize), 0)

        // Map to 16 bands using logarithmic frequency distribution
        let newBands = mapToBands(magnitudes, binCount: halfSize)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<16 {
                self.bands[i] = self.smoothing * self.bands[i] + (1 - self.smoothing) * newBands[i]
            }
        }
    }

    private func mapToBands(_ magnitudes: [Float], binCount: Int) -> [Float] {
        let bandCount = 16
        var result = [Float](repeating: 0, count: bandCount)

        // Logarithmic band edges from ~20Hz to ~20kHz mapped to FFT bins
        let minFreq: Float = 20.0
        let maxFreq: Float = 20000.0
        let logMin = log2(minFreq)
        let logMax = log2(maxFreq)

        for band in 0..<bandCount {
            let lowFreq = pow(2.0, logMin + (logMax - logMin) * Float(band) / Float(bandCount))
            let highFreq = pow(2.0, logMin + (logMax - logMin) * Float(band + 1) / Float(bandCount))

            // Convert frequency to bin index (assuming 44100 sample rate as approximate)
            let lowBin = max(0, Int(lowFreq / 22050.0 * Float(binCount)))
            let highBin = min(binCount - 1, Int(highFreq / 22050.0 * Float(binCount)))

            if lowBin <= highBin {
                var sum: Float = 0
                var count: Float = 0
                for bin in lowBin...highBin {
                    sum += magnitudes[bin]
                    count += 1
                }
                result[band] = sum / count
            }
        }

        // Normalize: dB range roughly -160 to 0, map to 0...1
        let minDB: Float = -60
        let maxDB: Float = 0
        for i in 0..<bandCount {
            let clamped = max(minDB, min(maxDB, result[i]))
            result[i] = (clamped - minDB) / (maxDB - minDB)
        }

        return result
    }
}

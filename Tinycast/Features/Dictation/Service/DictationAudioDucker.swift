import CoreAudio

@MainActor
final class DictationAudioDucker {
    private struct VolumeSnapshot {
        let control: AudioHardwareControl
        let original: Float
        var lastSet: Float
    }

    private var snapshot: VolumeSnapshot?
    private var transition: Task<Void, Never>?

    func begin() {
        if let snapshot {
            fade(to: snapshot.original * 0.1, release: false)
            return
        }
        guard let device = try? AudioHardwareSystem.shared.defaultOutputDevice,
            let control = try? device.controls.first(where: Self.isMainOutputVolume),
            let volume = try? control.volumeScalarValue,
            volume > 0
        else { return }
        snapshot = VolumeSnapshot(control: control, original: volume, lastSet: volume)
        fade(to: volume * 0.1, release: false)
    }

    func end() {
        guard let snapshot else { return }
        fade(to: snapshot.original, release: true)
    }

    func restoreImmediately() {
        transition?.cancel()
        if let snapshot,
            let current = try? snapshot.control.volumeScalarValue,
            abs(current - snapshot.lastSet) < 0.01
        {
            try? snapshot.control.setVolumeScalarValue(snapshot.original)
        }
        clear()
    }

    private func fade(to target: Float, release: Bool) {
        transition?.cancel()
        guard let snapshot,
            let start = try? snapshot.control.volumeScalarValue,
            abs(start - snapshot.lastSet) < 0.01
        else {
            clear()
            return
        }
        let first = start + (target - start) / 16
        do {
            try snapshot.control.setVolumeScalarValue(first)
            self.snapshot?.lastSet = (try? snapshot.control.volumeScalarValue) ?? first
        } catch {
            restoreImmediately()
            return
        }
        transition = Task { [weak self] in
            guard let self else { return }
            for step in 2...16 {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
                guard let snapshot = self.snapshot,
                    let current = try? snapshot.control.volumeScalarValue,
                    abs(current - snapshot.lastSet) < 0.01
                else { clear(); return }
                let volume = start + (target - start) * Float(step) / 16
                do {
                    try snapshot.control.setVolumeScalarValue(volume)
                    self.snapshot?.lastSet = (try? snapshot.control.volumeScalarValue) ?? volume
                } catch {
                    restoreImmediately()
                    return
                }
            }
            if release { clear() }
        }
    }

    private func clear() {
        transition?.cancel()
        transition = nil
        snapshot = nil
    }

    private static func isMainOutputVolume(_ control: AudioHardwareControl) -> Bool {
        guard (try? control.classID) == kAudioVolumeControlClassID else { return false }
        func value(for selector: AudioObjectPropertySelector) -> UInt32? {
            let address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard let data = try? control.propertyData(address: address, qualifier: nil),
                data.count == MemoryLayout<UInt32>.size
            else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        return value(for: kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput
            && value(for: kAudioControlPropertyElement) == kAudioObjectPropertyElementMain
    }
}

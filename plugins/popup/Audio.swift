import AppKit
import CoreAudio

// System frameworks only. This process owns popups, never another bar.
enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func writable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }

    static var current: AudioObjectID {
        scalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
    }

    static func deviceIDs() -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func devices() -> [(id: AudioObjectID, name: String)] {
        return deviceIDs().compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  scalar(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) == 1 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameProperty = address(kAudioObjectPropertyName)
            guard AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return (id, name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func uid(_ id: AudioObjectID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        var property = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...count).map { UInt32($0) } : []
    }

    static func controls(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        let main = address(selector, kAudioDevicePropertyScopeOutput)
        if writable(id, main) { return [main] }
        return channels(id).map { address(selector, kAudioDevicePropertyScopeOutput, $0) }.filter { writable(id, $0) }
    }

    static func volume(_ id: AudioObjectID) -> Float? {
        let values = controls(id, kAudioDevicePropertyVolumeScalar).compactMap { scalar(id, $0, Float(0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func muted(_ id: AudioObjectID) -> Bool {
        let values = controls(id, kAudioDevicePropertyMute).compactMap { scalar(id, $0, UInt32(0)) }
        return !values.isEmpty && values.allSatisfy { $0 != 0 }
    }

    static func setVolume(_ value: Float) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyVolumeScalar) { try set(id, property, min(1, max(0, value))) }
    }

    static func setMuted(_ value: Bool) throws {
        let id = current
        for property in controls(id, kAudioDevicePropertyMute) { try set(id, property, UInt32(value ? 1 : 0)) }
    }

    static func select(_ id: AudioObjectID) throws {
        try set(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func change(by points: Int) throws {
        guard let value = volume(current) else { return }
        try setVolume(Float(Int((value * 100).rounded()) + points) / 100)
    }

    // CoreAudio removes a listener only when given the same block object it was added with.
    typealias Listener = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    // The listener runs on the main queue.
    static func listen(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ listener: @escaping Listener) -> Bool {
        var address = address
        return AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr
    }

    static func unlisten(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ listener: @escaping Listener) {
        var address = address
        let status = AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        if status != noErr { logger.error("Removing an audio listener failed with status \(status, privacy: .public).") }
    }
}

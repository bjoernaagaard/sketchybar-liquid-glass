import Foundation
import IOBluetooth

struct BluetoothDevice: Identifiable {
    // The Bluetooth address is a stable identity, not a display name.
    let id: String
    let name: String?
    let isConnected: Bool
    let advertisesAudio: Bool
}

@MainActor
final class Bluetooth {
    enum StartResult {
        case started
        case alreadyConnecting
        case alreadyConnected
        case notPaired
        case stopped
        case failed(IOReturn)
    }

    struct ConnectionResult {
        let id: String
        let status: IOReturn
        let isConnected: Bool
    }

    private var requests: [String: ConnectionRequest] = [:]
    private var completions: [String: (ConnectionResult) -> Void] = [:]
    private var stopped = false

    func pairedDevices() -> [BluetoothDevice] {
        Self.devices().compactMap { device in
            guard let id = device.addressString, !id.isEmpty else { return nil }
            let audio = device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) ||
                (device.serviceClassMajor & BluetoothServiceClassMajor(kBluetoothServiceClassMajorAudio)) != 0
            return BluetoothDevice(id: id, name: device.name, isConnected: device.isConnected(), advertisesAudio: audio)
        }
    }

    func isConnecting(_ id: String) -> Bool {
        requests[id] != nil
    }

    // Call only in response to an explicit user action.
    func connect(_ id: String, completion: @escaping (ConnectionResult) -> Void) -> StartResult {
        guard !stopped else { return .stopped }
        guard requests[id] == nil else { return .alreadyConnecting }
        guard let device = Self.devices().first(where: { $0.addressString == id }) else { return .notPaired }
        guard !device.isConnected() else { return .alreadyConnected }

        let request = ConnectionRequest(device: device) { [weak self] status, connected in
            guard let self else { return }
            self.requests.removeValue(forKey: id)
            let completion = self.completions.removeValue(forKey: id)
            completion?(ConnectionResult(id: id, status: status, isConnected: connected))
        }
        requests[id] = request
        completions[id] = completion
        let status = device.openConnection(request)
        guard status == kIOReturnSuccess else {
            requests.removeValue(forKey: id)
            completions.removeValue(forKey: id)
            request.releaseCompletion()
            // Another process may have connected the device since the check above.
            return device.isConnected() ? .alreadyConnected : .failed(status)
        }
        return .started
    }

    // IOBluetooth provides no cancellation API for openConnection. Keep callback
    // targets alive until completion, but suppress client callbacks after shutdown.
    func shutdown() {
        stopped = true
        completions.removeAll()
    }

    private static func devices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }
}

@MainActor
private final class ConnectionRequest: NSObject {
    private let device: IOBluetoothDevice
    private var completion: ((IOReturn, Bool) -> Void)?

    init(device: IOBluetoothDevice, completion: @escaping (IOReturn, Bool) -> Void) {
        self.device = device
        self.completion = completion
    }

    // The SDK does not document the callback thread. Only the status crosses
    // the actor boundary; the framework device stays on the main actor.
    @objc(connectionComplete:status:)
    nonisolated func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        Task { @MainActor [self] in
            finish(status)
        }
    }

    private func finish(_ status: IOReturn) {
        let callback = completion
        completion = nil
        callback?(status, device.isConnected())
    }

    func releaseCompletion() {
        completion = nil
    }
}

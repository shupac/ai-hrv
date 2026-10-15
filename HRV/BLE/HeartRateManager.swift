import CoreBluetooth
import Foundation
import Observation

/// Connects to a BLE Heart Rate Service strap and streams measurements.
/// Remembers the chosen strap and keeps a pending connect alive so it reconnects
/// automatically (also in the background) after dropouts.
@Observable
final class HeartRateManager: NSObject {
    enum State: Equatable {
        case poweredOff, unauthorized, unsupported, idle, scanning, connecting, connected, reconnecting

        var label: String {
            switch self {
            case .poweredOff: "Bluetooth off"
            case .unauthorized: "Bluetooth permission denied"
            case .unsupported: "Bluetooth unavailable"
            case .idle: "Not connected"
            case .scanning: "Scanning…"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .reconnecting: "Reconnecting…"
            }
        }
    }

    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int?             // nil for devices already connected to the phone
        var isHeartRate: Bool
        var alreadyConnected = false
    }

    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    private static let savedDeviceKey = "savedDeviceID"
    private static let restoreID = "hrv.central"

    private(set) var state: State = .idle
    private(set) var devices: [Device] = []
    private(set) var deviceName: String?
    private(set) var lastPacket: Date?
    private(set) var battery: Int?          // strap battery %, if it reports one

    @ObservationIgnored var onMeasurement: ((HeartRateMeasurement, Date) -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var userDisconnected = false

    var savedDeviceID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.savedDeviceKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.savedDeviceKey) }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    // MARK: - Actions

    func startScan() {
        guard central.state == .poweredOn else { return }
        // A strap already connected to the phone (e.g. via Settings or another app) stops advertising,
        // so it never shows up in a scan. List those first.
        devices = central.retrieveConnectedPeripherals(withServices: [Self.hrService]).map {
            Device(id: $0.identifier, name: $0.name ?? "Heart-rate monitor", rssi: nil,
                   isHeartRate: true, alreadyConnected: true)
        }
        if peripheral == nil { state = .scanning }
        // Unfiltered: some straps don't put 0x180D in their advertisement. Foreground only, so no filter is needed.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(to id: UUID) {
        central.stopScan()
        if let p = peripheral, p.identifier != id {
            userDisconnected = true
            central.cancelPeripheralConnection(p)
        }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        savedDeviceID = id
        connect(p)
    }

    /// Disconnects and forgets the strap.
    func forget() {
        savedDeviceID = nil
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        deviceName = nil
        state = .idle
        startScan()
    }

    // MARK: - Private

    private func connect(_ p: CBPeripheral) {
        userDisconnected = false
        peripheral = p
        deviceName = p.name
        p.delegate = self
        state = .connecting
        central.connect(p) // no timeout: iOS keeps trying until the strap is in range
    }

    private func subscribe(_ p: CBPeripheral) {
        if let c = p.services?.first(where: { $0.uuid == Self.hrService })?
            .characteristics?.first(where: { $0.uuid == Self.hrMeasurement }) {
            p.setNotifyValue(true, for: c)
        } else {
            p.discoverServices([Self.hrService, Self.batteryService])
        }
    }

    private func resume() {
        if let p = peripheral {
            if p.state == .connected {
                state = .connected
                subscribe(p)
            } else {
                connect(p)
            }
        } else if let id = savedDeviceID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else if let p = central.retrieveConnectedPeripherals(withServices: [Self.hrService]).first {
            savedDeviceID = p.identifier
            connect(p)
        } else {
            startScan()
        }
    }
}

extension HeartRateManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: resume()
        case .poweredOff:
            state = .poweredOff
            onDisconnect?()
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            deviceName = p.name
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let isHR = services.contains(Self.hrService) || Self.looksLikeHeartRateMonitor(name)
        // Unnamed non-HR devices (phones, beacons, …) are just noise in the picker.
        guard isHR || name != nil else { return }
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            guard !devices[i].alreadyConnected else { return }
            devices[i].rssi = rssi.intValue
            devices[i].isHeartRate = devices[i].isHeartRate || isHR
        } else {
            devices.append(Device(id: p.identifier, name: name ?? "Heart-rate monitor",
                                  rssi: rssi.intValue, isHeartRate: isHR))
        }
    }

    static func looksLikeHeartRateMonitor(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return ["powr", "hrm", "heart", "polar", "wahoo", "tickr", "garmin", "coospo", "magene"]
            .contains { n.contains($0) }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        deviceName = p.name
        p.discoverServices([Self.hrService, Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard !userDisconnected, p == peripheral else { return }
        state = .reconnecting
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        onDisconnect?()
        guard !userDisconnected, p == peripheral else { return }
        state = .reconnecting
        central.connect(p)
    }
}

extension HeartRateManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            if s.uuid == Self.hrService { p.discoverCharacteristics([Self.hrMeasurement], for: s) }
            if s.uuid == Self.batteryService { p.discoverCharacteristics([Self.batteryLevel], for: s) }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == Self.hrMeasurement { p.setNotifyValue(true, for: c) }
            if c.uuid == Self.batteryLevel {
                p.readValue(for: c)
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == Self.batteryLevel, let level = c.value?.first {
            battery = Int(level)
            return
        }
        guard c.uuid == Self.hrMeasurement, let data = c.value,
              let m = HeartRateParser.parse(data) else { return }
        let now = Date()
        lastPacket = now
        onMeasurement?(m, now)
    }
}

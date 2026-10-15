// Verifies that a BLE heart-rate strap sends RR intervals.
// Usage: swift tools/hrscan.swift [name-substring]
// Terminal needs Bluetooth permission (System Settings → Privacy & Security → Bluetooth).

import CoreBluetooth
import Foundation

let hrService = CBUUID(string: "180D")
let hrMeasurement = CBUUID(string: "2A37")
let bodySensorLocation = CBUUID(string: "2A38")
let deviceInfoService = CBUUID(string: "180A")
let nameFilter = CommandLine.arguments.dropFirst().first?.lowercased()

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var packets = 0
    var packetsWithRR = 0
    var rrCount = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // A strap already connected to this Mac won't advertise.
            if let p = central.retrieveConnectedPeripherals(withServices: [hrService]).first(where: matches) {
                print("Using already-connected \(p.name ?? "?")")
                connect(p)
            } else {
                print("Scanning for Heart Rate Service (0x180D)… wear the strap so it wakes up.")
                central.scanForPeripherals(withServices: [hrService])
            }
        case .unauthorized:
            print("Bluetooth permission denied for this terminal app."); exit(1)
        case .poweredOff:
            print("Bluetooth is off."); exit(1)
        default:
            break
        }
    }

    func matches(_ p: CBPeripheral) -> Bool {
        guard let nameFilter else { return true }
        return (p.name ?? "").lowercased().contains(nameFilter)
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        print("Found \(p.name ?? "(no name)") rssi=\(rssi) id=\(p.identifier)")
        guard peripheral == nil, matches(p) else { return }
        central.stopScan()
        connect(p)
    }

    func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected to \(p.name ?? "?")")
        p.discoverServices([hrService, deviceInfoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "unknown")"); exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("Disconnected: \(error?.localizedDescription ?? "")"); summary(); exit(0)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == hrMeasurement {
                p.setNotifyValue(true, for: c)
            } else if c.properties.contains(.read) {
                p.readValue(for: c)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        if c.uuid == hrMeasurement {
            printMeasurement(data)
        } else if c.uuid == bodySensorLocation, let loc = data.first {
            let names = ["Other", "Chest", "Wrist", "Finger", "Hand", "Ear lobe", "Foot"]
            print("Body sensor location: \(loc < names.count ? names[Int(loc)] : "\(loc)")")
        } else if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            print("\(c.uuid): \(s)")
        }
    }

    func printMeasurement(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { print("short packet"); return }
        let flags = b[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 != 0 { bpm = Int(b[1]) | Int(b[2]) << 8; i = 3 } else { bpm = Int(b[1]); i = 2 }
        if flags & 0x08 != 0 { i += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count {
                rr.append(Double(Int(b[i]) | Int(b[i + 1]) << 8) * 1000 / 1024)
                i += 2
            }
        }
        packets += 1
        if !rr.isEmpty { packetsWithRR += 1; rrCount += rr.count }
        let hex = b.map { String(format: "%02x", $0) }.joined(separator: " ")
        let contact = flags & 0x04 == 0 ? "n/a" : (flags & 0x02 != 0 ? "yes" : "NO")
        let rrText = rr.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        print("[\(hex)] flags=0x\(String(format: "%02x", flags)) hr16=\(flags & 0x01 != 0) contact=\(contact) "
              + "energy=\(flags & 0x08 != 0) rrFlag=\(flags & 0x10 != 0)  BPM=\(bpm)  RR(ms)=[\(rrText)]")
    }

    func summary() {
        print("\n\(packets) packets, \(packetsWithRR) with RR, \(rrCount) RR intervals total.")
        print(packetsWithRR > 0 ? "PASS: strap transmits RR intervals." : "FAIL: no RR intervals seen.")
    }
}

let scanner = Scanner()
signal(SIGINT) { _ in scanner.summary(); exit(0) }
RunLoop.main.run()

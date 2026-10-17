import Foundation
import Testing
@testable import HRV

/// Example frames come from polar-ble-sdk: technical_documentation/online_measurement.pdf (doc)
/// and sources/iOS/ios-communications/Tests/iOSCommunicationsTests/AccDataTest.swift (SDK test).
struct PolarPMDTests {
    private static func hex(_ s: String) -> Data {
        Data(s.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // MARK: - Control point

    @Test func features() {
        // Doc fig. 1, Verity Sense: 0x6E = PPG, ACC, PPI, gyro, magnetometer.
        #expect(PolarPMD.supportsAccelerometer(features: Self.hex("0F 6E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")))
        #expect(!PolarPMD.supportsAccelerometer(features: Self.hex("0F 01")))   // ECG only
        #expect(!PolarPMD.supportsAccelerometer(features: Self.hex("F0 04")))
        #expect(!PolarPMD.supportsAccelerometer(features: Data([0x0F])))
    }

    @Test func h10SettingsChooseLowRateAndStart() throws {
        // Doc fig. 2, H10 response to [01 02].
        let data = Self.hex("F0 01 02 00 00 00 04 19 00 32 00 64 00 C8 00 01 01 10 00 02 03 02 00 04 00 08 00")
        let r = try #require(PolarPMD.Response(data))
        #expect(r.opCode == PolarPMD.getSettingsOp)
        #expect(r.measurementType == PolarPMD.accType)
        #expect(r.status == PolarPMD.Response.success)
        let available = PolarPMD.parseSettings(r.parameters)
        #expect(available[.sampleRate] == [25, 50, 100, 200])
        #expect(available[.resolution] == [16])
        #expect(available[.range] == [2, 4, 8])

        let s = try #require(PolarPMD.AccSettings(available: available))
        #expect(s.sampleRate == 25 && s.resolution == 16 && s.range == 8 && s.channels == nil)
        // Same layout as the doc's H10 start command (fig. 3), with 25 Hz instead of 200 Hz.
        #expect(s.startCommand == Self.hex("02 02 00 01 19 00 01 01 10 00 02 01 08 00"))
    }

    @Test func veritySenseSettingsIncludeChannels() throws {
        // Doc fig. 2, Verity Sense: only 52 Hz, so that is chosen; the start command matches fig. 3.
        let r = try #require(PolarPMD.Response(Self.hex("F0 01 02 00 00 00 01 34 00 01 01 10 00 02 01 08 00 04 01 03")))
        let s = try #require(PolarPMD.AccSettings(available: PolarPMD.parseSettings(r.parameters)))
        #expect(s.startCommand == Self.hex("02 02 00 01 34 00 01 01 10 00 02 01 08 00 04 01 03"))
    }

    @Test func startResponseFactor() throws {
        // Doc fig. 3: H10 sends no factor; Verity Sense sends 0x397FDA40 ≈ 0.000244.
        let h10 = try #require(PolarPMD.Response(Self.hex("F0 02 02 00 00 01")))
        #expect(h10.opCode == PolarPMD.startOp && h10.status == PolarPMD.Response.success)
        #expect(PolarPMD.factor(fromStartParameters: h10.parameters) == 1)
        let verity = try #require(PolarPMD.Response(Self.hex("F0 02 02 00 00 05 01 40 DA 7F 39")))
        #expect(abs(PolarPMD.factor(fromStartParameters: verity.parameters) - 0.000244) < 1e-9)
        // Doc fig. 4: stop response.
        #expect(PolarPMD.Response(Self.hex("F0 03 02 00 00"))?.opCode == PolarPMD.stopOp)
        #expect(PolarPMD.Response(Self.hex("0F 02 00 00")) == nil)
    }

    // MARK: - Frames

    @Test func h10RawFrame() throws {
        // Doc fig. 3, H10 type 1 (16-bit) frame, first two samples. The doc labels x = 0xFF45 as -184;
        // it is -187.
        let data = Self.hex("02 EA 54 A2 42 8B 45 52 08 01 45 FF E4 FF B5 03 45 FF E4 FF B8 03")
        let f = try #require(PolarPMD.parseAccFrame(data, previousTimestamp: 0, sampleRate: 25, factor: 1))
        #expect(f.timestamp == 599_618_164_814_402_794)
        #expect(f.samples.map { [$0.x, $0.y, $0.z] } == [[-187, -28, 949], [-187, -28, 952]])
        // First frame: spaced by the sample rate, ending at the frame timestamp.
        #expect(f.samples.map(\.sensorTime) == [599_618_164_814_402_794 - 40_000_000, 599_618_164_814_402_794] as [UInt64])
    }

    @Test func sdkRawType1Frame() throws {
        let content = Self.hex("""
            F7 FF FF FF E7 03 F8 FF FE FF E5 03 F9 FF FF FF E5 03 FA FF FF FF E6 03 FA FF FE FF E6 03 \
            F9 FF FF FF E5 03 F8 FF FF FF E6 03 F8 FF FE FF E6 03 FA FF FF FF E5 03 FA FF FF FF E7 03 \
            FA FF FF FF E5 03 F8 FF FF FF E6 03 F7 FF FF FF E6 03 F8 FF FE FF E6 03 F9 FF FE FF E7 03 \
            F9 FF 00 00 E6 03 F9 FF FF FF E6 03 F7 FF FE FF E5 03 F9 FF FF FF E5 03 F9 FF FF FF E5 03 \
            FA FF 00 00 E6 03 F9 FF FE FF E6 03 F8 FF FF FF E6 03 F8 FF FF FF E5 03 F9 FF FF FF E6 03 \
            F9 FF FF FF E5 03 FA FF FF FF E6 03 F9 FF FF FF E5 03 F9 FF FF FF E5 03 F8 FF FE FF E6 03 \
            F9 FF FF FF E6 03 F9 FF FF FF E6 03 F9 FF 00 00 E5 03 F9 FF FE FF E6 03 F8 FF FE FF E6 03 \
            F7 FF FE FF E6 03
            """)
        let header = Self.hex("02 00 94 35 77 00 00 00 00 01")   // timestamp 2_000_000_000, raw type 1
        let f = try #require(PolarPMD.parseAccFrame(header + content, previousTimestamp: 0, sampleRate: 52, factor: 1))
        #expect(f.samples.count == content.count / 6)
        #expect([f.samples[0].x, f.samples[0].y, f.samples[0].z] == [-9, -1, 999])
        #expect([f.samples[1].x, f.samples[1].y, f.samples[1].z] == [-8, -2, 997])
        #expect(f.samples.last?.sensorTime == 2_000_000_000)
    }

    @Test func sdkCompressedType0Frame() throws {
        let content = Self.hex("""
            71 07 F0 6A 9E 8D 0A 38 BE 5C BE BA 2F 96 B3 EE 4B E5 AD FB 42 B9 EB BE 4C FE BA 2F 92 BF \
            EE 4B E4 B1 FB 12 B9 EC BD 3C 3E BB 2F 8F D3 DE 4B E3 B5 F7 D2 B8 ED BD 30 7E 7B 2F 8B E3 \
            CE 8B E2 BA F7 A2 B8 EE BC 20 BE 7B 2F 88 F3 CE CB E1 BD EF 52 F8 EF BC 18 FE 3B 2F 84 03 \
            BF CB E0 C2 EF 32 B8 F0 BB 04 4E BC 2E 81 13 AF 0B E0 C6 EF F2 F7 F1 B9 FC 7D BC 2E 7D 27 \
            9F 4B DF CA EB C2 F7 F2 B8 EC CD 7C 2E 7B 37 8F 4B DE CE E3 92 F7 F3 B8 E0 0D FD 2D 77 4B \
            7F CB DD D2 DF 62 37 F5 B7 D4 4D BD 2D 74 5B 6F CB DC D7 D7 32 37 F6 B5 C8 8D 7D 2D 71 6B \
            4F 4B DC DC D3 F2 36 F7 B4 BC DD FD 2C 6F 7B 3F 4B DB E0 CF D2 36 F8 B2 B0 2D BE 2C 6C 8F \
            1F CB DA E3 C7 A2 76 F9
            """)
        // Reference sample, then one block of 56 deltas of 10 bits.
        let raw = try #require(PolarPMD.decodeDeltaFrames([UInt8](content), channels: 3, resolution: 16))
        #expect(raw.count == 57)
        #expect(raw[0] == [1905, 27376, -29282])
        #expect(raw[1] == [2095, 27271, -29367])  // deltas +190, -105, -85

        // Compressed type 0 is in G: × factor × 1000 gives mG.
        let header = Self.hex("02 00 94 35 77 00 00 00 00 80")
        let f = try #require(PolarPMD.parseAccFrame(header + content, previousTimestamp: 100, sampleRate: 52, factor: 2.44e-4))
        #expect(f.samples.count == 57)
        #expect([f.samples[0].x, f.samples[0].y, f.samples[0].z] == [465, 6680, -7145])
        #expect([f.samples[1].x, f.samples[1].y, f.samples[1].z] == [511, 6654, -7166])
        #expect(f.samples.allSatisfy { max(abs($0.x), abs($0.y), abs($0.z)) <= 8000 })   // 8 G range
        // Spaced evenly from the previous frame's timestamp.
        #expect(f.samples.first?.sensorTime == 35_087_818)
        #expect(f.samples.last?.sensorTime == 2_000_000_000)
    }

    @Test func sdkCompressedType1Frame() throws {
        // Reference (-15, 20, 1008), one block of one 6-bit delta per channel: (-5, -3, 0).
        let data = Self.hex("02 66 00 00 00 00 00 00 00 81 F1 FF 14 00 F0 03 06 01 7B 0F 08")
        let f = try #require(PolarPMD.parseAccFrame(data, previousTimestamp: 100, sampleRate: 52, factor: 1))
        #expect(f.samples == [AccSample(sensorTime: 101, x: -15, y: 20, z: 1008),
                              AccSample(sensorTime: 102, x: -20, y: 17, z: 1008)])
    }

    @Test func docDeltaSamples() {
        // Doc fig. 3, Verity Sense delta frame: reference (-48, 357, 4068), then a block of 8-bit deltas
        // FC 07 FF, 0C 13 F2, … The doc cuts the block off after 2 of its 29 (0x1D) samples, so as given
        // it is truncated and rejected.
        var content: [UInt8] = [0xD0, 0xFF, 0x65, 0x01, 0xE4, 0x0F, 0x08, 0x1D, 0xFC, 0x07, 0xFF, 0x0C, 0x13, 0xF2]
        #expect(PolarPMD.decodeDeltaFrames(content, channels: 3, resolution: 16) == nil)
        // With the count set to the 2 samples shown, they decode to the doc's values.
        content[7] = 0x02
        #expect(PolarPMD.decodeDeltaFrames(content, channels: 3, resolution: 16)
                == [[-48, 357, 4068], [-52, 364, 4067], [-40, 383, 4053]])
    }

    @Test func malformedFrames() {
        let header = Self.hex("02 00 94 35 77 00 00 00 00")
        #expect(PolarPMD.parseAccFrame(Data(), previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        #expect(PolarPMD.parseAccFrame(header, previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        // Empty or misaligned raw content.
        #expect(PolarPMD.parseAccFrame(header + [0x01], previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        #expect(PolarPMD.parseAccFrame(header + [0x01, 1, 2, 3, 4, 5, 6, 7], previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        // Not ACC (ECG), and an unknown frame type.
        #expect(PolarPMD.parseAccFrame(Self.hex("00 00 94 35 77 00 00 00 00 00 01 02 03"), previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        #expect(PolarPMD.parseAccFrame(header + [0x05, 1, 2, 3], previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        // Compressed with no content, and a zero-width delta block.
        #expect(PolarPMD.parseAccFrame(header + [0x81], previousTimestamp: 0, sampleRate: 25, factor: 1) == nil)
        #expect(PolarPMD.decodeDeltaFrames([1, 0, 2, 0, 3, 0, 0x00, 0x01], channels: 3, resolution: 16) == nil)
    }

    // MARK: - Timestamps

    @Test func sampleTimesFallBackToRateAfterGap() {
        // 4 samples at 25 Hz; the previous frame is 1 s back (dropped frames), so the rate is used.
        #expect(PolarPMD.sampleTimes(count: 4, last: 2_000_000_000, previous: 1_000_000_000, sampleRate: 25)
                == [1_880_000_000, 1_920_000_000, 1_960_000_000, 2_000_000_000])
        // Previous frame 160 ms back: spacing measured from timestamps.
        #expect(PolarPMD.sampleTimes(count: 4, last: 2_000_000_000, previous: 1_840_000_000, sampleRate: 25)
                == [1_880_000_000, 1_920_000_000, 1_960_000_000, 2_000_000_000])
        // A timestamp going backwards is ignored too.
        #expect(PolarPMD.sampleTimes(count: 2, last: 100, previous: 200, sampleRate: 25) == [0, 100])
    }

    @Test func phoneDates() {
        let f = AccFrame(timestamp: 2_000_000_000, samples: [AccSample(sensorTime: 1_960_000_000, x: 0, y: 0, z: 0)])
        let received = Date(timeIntervalSince1970: 1000)
        #expect(abs(f.date(of: f.samples[0], receivedAt: received).timeIntervalSince1970 - 999.96) < 1e-6)
    }
}

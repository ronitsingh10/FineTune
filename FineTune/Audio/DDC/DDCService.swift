// FineTune/Audio/DDC/DDCService.swift
// Low-level DDC/CI communication via IOKit private APIs

#if !APP_STORE

import Foundation
import IOKit
import os

// MARK: - IOAVService Dynamic Loading

/// Dynamically loads private IOAVService APIs from IOMobileFramebuffer framework.
/// These are undocumented Apple Silicon APIs for I2C communication with displays.
// THREAD SAFETY: ensureLoaded() must only be called from ddcQueue (serial).
// This constraint is currently enforced by all callers going through
// discoverServices() which runs on ddcQueue.
enum IOAVServiceLoader {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafePointer<UInt8>, UInt32) -> IOReturn

    private static var createFn: CreateWithServiceFn?
    private static var readFn: ReadI2CFn?
    private static var writeFn: WriteI2CFn?
    private static var didLoad = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DDCService")

    static func ensureLoaded() -> Bool {
        guard !didLoad else { return createFn != nil }
        didLoad = true

        let path = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
        guard let handle = dlopen(path, RTLD_NOW) else {
            logger.error("Failed to dlopen IOMobileFramebuffer: \(String(cString: dlerror()))")
            return false
        }

        guard let c = dlsym(handle, "IOAVServiceCreateWithService"),
              let r = dlsym(handle, "IOAVServiceReadI2C"),
              let w = dlsym(handle, "IOAVServiceWriteI2C") else {
            logger.error("Failed to resolve IOAVService symbols")
            return false
        }

        createFn = unsafeBitCast(c, to: CreateWithServiceFn.self)
        readFn = unsafeBitCast(r, to: ReadI2CFn.self)
        writeFn = unsafeBitCast(w, to: WriteI2CFn.self)
        logger.info("IOAVService APIs loaded successfully")
        return true
    }

    static func createService(for entry: io_service_t) -> CFTypeRef? {
        guard ensureLoaded(), let fn = createFn else { return nil }
        return fn(kCFAllocatorDefault, entry)?.takeRetainedValue()
    }

    static func readI2C(service: CFTypeRef, chipAddress: UInt32, dataAddress: UInt32,
                        buffer: UnsafeMutablePointer<UInt8>, size: UInt32) -> IOReturn {
        guard let fn = readFn else { return kIOReturnNotReady }
        return fn(service, chipAddress, dataAddress, buffer, size)
    }

    static func writeI2C(service: CFTypeRef, chipAddress: UInt32, dataAddress: UInt32,
                         buffer: UnsafePointer<UInt8>, size: UInt32) -> IOReturn {
        guard let fn = writeFn else { return kIOReturnNotReady }
        return fn(service, chipAddress, dataAddress, buffer, size)
    }
}

// MARK: - DDC Error

enum DDCError: Error {
    case apiNotAvailable
    case serviceCreationFailed
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    case checksumMismatch
    case invalidResponse
    case unsupportedVCP
}

// MARK: - DDC Service

/// Handles DDC/CI I2C communication with a single display.
/// Protocol implementation matches MonitorControl (Arm64DDC.swift).
/// All methods are synchronous and should be called from a background queue.
final class DDCService: @unchecked Sendable {
    private let service: CFTypeRef

    // I2C addressing (DDC/CI standard)
    private let chipAddress: UInt32 = 0x37       // 7-bit DDC slave address
    private let writeAddress: UInt32 = 0x51      // DDC/CI host source address (write sub-address)

    // Timing (matches MonitorControl defaults)
    private let writeSleepTime: UInt32 = 10_000  // 10ms before each write
    private let numWriteCycles = 2               // Write command twice per attempt
    private let readSleepTime: UInt32 = 50_000   // 50ms wait before read
    private let retryCount = 5                   // Full write+read retry cycles
    private let retrySleepTime: UInt32 = 100_000 // 100ms between retries

    init(service: CFTypeRef) {
        self.service = service
    }

    // MARK: - I2C Write/Read Primitives

    /// Writes a DDC packet and reads the response.
    /// Writes the command `numWriteCycles` times (with pre-write delays), waits, then reads once.
    private func i2cWriteRead(packet: [UInt8]) throws -> [UInt8] {
        // Write command (potentially multiple times, matching MonitorControl)
        var writeSuccess = false
        for _ in 0..<numWriteCycles {
            usleep(writeSleepTime)
            let result = packet.withUnsafeBufferPointer { buf in
                IOAVServiceLoader.writeI2C(service: service, chipAddress: chipAddress,
                                           dataAddress: writeAddress, buffer: buf.baseAddress!, size: UInt32(buf.count))
            }
            if result == kIOReturnSuccess { writeSuccess = true }
        }
        guard writeSuccess else { throw DDCError.writeFailed(kIOReturnError) }

        // Wait for monitor to prepare response
        usleep(readSleepTime)

        // Read response (11 bytes) — read address is 0, not 0x51
        var reply = [UInt8](repeating: 0, count: 11)
        let readResult = reply.withUnsafeMutableBufferPointer { buf in
            IOAVServiceLoader.readI2C(service: service, chipAddress: chipAddress,
                                      dataAddress: 0, buffer: buf.baseAddress!, size: UInt32(buf.count))
        }
        guard readResult == kIOReturnSuccess else { throw DDCError.readFailed(readResult) }

        return reply
    }

    /// Writes a DDC packet without reading a response.
    private func i2cWrite(packet: [UInt8]) throws {
        for _ in 0..<numWriteCycles {
            usleep(writeSleepTime)
            let result = packet.withUnsafeBufferPointer { buf in
                IOAVServiceLoader.writeI2C(service: service, chipAddress: chipAddress,
                                           dataAddress: writeAddress, buffer: buf.baseAddress!, size: UInt32(buf.count))
            }
            if result == kIOReturnSuccess { return }
        }
        throw DDCError.writeFailed(kIOReturnError)
    }

    // MARK: - VCP Commands

    /// Reads a VCP feature value from the display.
    func readVCP(_ code: UInt8) throws -> (current: UInt16, max: UInt16) {
        let logger = Self.logger
        // Build Get VCP Feature request: [length|0x80, 0x01, code, checksum]
        var packet: [UInt8] = [0x82, 0x01, code]
        packet.append(writeChecksum(packet))

        var lastError: DDCError = .readFailed(kIOReturnError)

        for attempt in 0..<retryCount {
            do {
                let reply = try i2cWriteRead(packet: packet)

                // Check for all-zeros (no DDC support — e.g. built-in display)
                if reply.allSatisfy({ $0 == 0 }) {
                    logger.debug("readVCP(0x\(String(code, radix: 16))): all-zero response (no DDC)")
                    throw DDCError.invalidResponse
                }

                // Check for NULL response (0x6E, 0x80 = monitor busy)
                if reply[0] == 0x6E && reply[1] == 0x80 {
                    logger.debug("readVCP(0x\(String(code, radix: 16))): null response, attempt \(attempt + 1)/\(self.retryCount)")
                    lastError = .invalidResponse
                    if attempt < retryCount - 1 { usleep(retrySleepTime) }
                    continue
                }

                let hex = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.debug("readVCP(0x\(String(code, radix: 16))): reply: \(hex)")

                return try parseVCPResponse(reply, expectedCode: code)
            } catch let error as DDCError {
                lastError = error
                if attempt < retryCount - 1 { usleep(retrySleepTime) }
            }
        }

        throw lastError
    }

    /// Writes a VCP feature value to the display.
    func writeVCP(_ code: UInt8, value: UInt16) throws {
        // Build Set VCP Feature: [length|0x80, 0x03, code, value_hi, value_lo, checksum]
        var packet: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        packet.append(writeChecksum(packet))

        var lastError: DDCError = .writeFailed(kIOReturnError)

        for attempt in 0..<retryCount {
            do {
                try i2cWrite(packet: packet)
                return
            } catch let error as DDCError {
                lastError = error
                if attempt < retryCount - 1 { usleep(retrySleepTime) }
            }
        }

        throw lastError
    }

    // MARK: - EDID

    /// Reads EDID data directly from the monitor via I2C (address 0x50).
    /// This is more reliable than reading from the IORegistry, because the IORegistry
    /// parent walk from DCPAVServiceProxy often fails on Apple Silicon (IODisplay nodes
    /// are siblings, not ancestors of DCPAVServiceProxy entries).
    /// Returns the EDID manufacturer/product/serial identifiers, or nil if the read fails.
    func readEDID() -> (vendorID: UInt32, productID: UInt32, serialNumber: UInt32)? {
        // EDID lives at I2C slave address 0x50, starting at offset 0
        let edidAddress: UInt32 = 0x50
        var edidData = [UInt8](repeating: 0, count: 128)
        let result = edidData.withUnsafeMutableBufferPointer { buf in
            IOAVServiceLoader.readI2C(service: service, chipAddress: edidAddress,
                                      dataAddress: 0, buffer: buf.baseAddress!, size: 128)
        }
        guard result == kIOReturnSuccess else { return nil }

        // Validate EDID header: 00 FF FF FF FF FF FF 00
        let expectedHeader: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard Array(edidData[0..<8]) == expectedHeader else { return nil }

        // Validate checksum (all 128 bytes should sum to 0 mod 256)
        let checksum: UInt8 = edidData.reduce(0, &+)
        guard checksum == 0 else { return nil }

        // Manufacturer ID: bytes 8-9, big-endian (ISA PnP vendor code)
        // Matches CGDisplayVendorNumber()
        let vendorID = UInt32(edidData[8]) << 8 | UInt32(edidData[9])

        // Product code: bytes 10-11, little-endian
        // Matches CGDisplayModelNumber()
        let productID = UInt32(edidData[10]) | UInt32(edidData[11]) << 8

        // Serial number: bytes 12-15, little-endian
        // Matches CGDisplaySerialNumber()
        let serialNumber = UInt32(edidData[12]) | UInt32(edidData[13]) << 8
            | UInt32(edidData[14]) << 16 | UInt32(edidData[15]) << 24

        return (vendorID: vendorID, productID: productID, serialNumber: serialNumber)
    }

    // MARK: - Convenience

    /// Checks if this display supports audio volume control (VCP 0x62).
    func supportsAudioVolume() -> Bool {
        (try? readVCP(0x62)) != nil
    }

    /// Gets current audio volume (0-100).
    func getAudioVolume() throws -> (current: Int, max: Int) {
        let result = try readVCP(0x62)
        return (current: Int(result.current), max: Int(result.max))
    }

    /// Sets audio volume (clamped to 0-100).
    func setAudioVolume(_ volume: Int) throws {
        try writeVCP(0x62, value: UInt16(max(0, min(100, volume))))
    }

    // MARK: - Packet Helpers

    /// Checksum for outgoing packets: XOR of destination (0x6E) and source (0x51) with all data bytes.
    private func writeChecksum(_ data: [UInt8]) -> UInt8 {
        var checksum = UInt8(truncatingIfNeeded: (chipAddress << 1) ^ writeAddress)  // 0x6E ^ 0x51 = 0x3F
        for byte in data { checksum ^= byte }
        return checksum
    }

    /// Checksum for validating display responses: initial value 0x50 per DDC/CI spec.
    private func responseChecksum(_ data: [UInt8]) -> UInt8 {
        var checksum: UInt8 = 0x50
        for byte in data { checksum ^= byte }
        return checksum
    }

    private func parseVCPResponse(_ reply: [UInt8], expectedCode: UInt8) throws -> (current: UInt16, max: UInt16) {
        // Response: [source, length, 0x02, result, code, type, max_h, max_l, cur_h, cur_l, checksum]
        guard reply.count >= 11 else { throw DDCError.invalidResponse }

        let expected = responseChecksum(Array(reply[0..<10]))
        guard reply[10] == expected else { throw DDCError.checksumMismatch }
        guard reply[3] == 0 else { throw DDCError.unsupportedVCP }
        guard reply[4] == expectedCode else { throw DDCError.invalidResponse }

        let maxValue = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let currentValue = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        return (current: currentValue, max: maxValue)
    }
}

// MARK: - IOAVService Discovery

extension DDCService {
    /// Finds all DCPAVServiceProxy entries in the IORegistry and creates DDCService instances.
    /// Returns pairs of (io_service_t entry, DDCService).
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DDCService")

    static func discoverServices() -> [(entry: io_service_t, service: DDCService)] {
        guard IOAVServiceLoader.ensureLoaded() else {
            logger.error("discoverServices: IOAVService APIs not available")
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        )
        guard result == kIOReturnSuccess else {
            logger.error("discoverServices: IOServiceGetMatchingServices failed: \(result)")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [(entry: io_service_t, service: DDCService)] = []
        var entryCount = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            entryCount += 1

            // Skip built-in displays — they don't support DDC
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "Embedded" {
                logger.debug("discoverServices: skipping embedded display (entry \(entryCount))")
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
                continue
            }

            if let avService = IOAVServiceLoader.createService(for: entry) {
                services.append((entry: entry, service: DDCService(service: avService)))
                logger.debug("discoverServices: created IOAVService for entry \(entryCount) (location: \(location ?? "unknown"))")
            } else {
                logger.debug("discoverServices: IOAVServiceCreateWithService failed for entry \(entryCount)")
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iterator)
        }

        logger.info("discoverServices: \(entryCount) DCPAVServiceProxy entries, \(services.count) IOAVService(s) created")
        return services
    }
}

#endif

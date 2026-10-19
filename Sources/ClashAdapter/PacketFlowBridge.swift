import Darwin
import Foundation
import NetworkExtension
import os

protocol PacketFlowIO: AnyObject {
    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool
}

extension NEPacketTunnelFlow: PacketFlowIO {}

enum PacketFlowBridgeError: LocalizedError {
    case systemCall(String, Int32)
    case malformedBatch
    case malformedFrame
    case packetWriteRejected

    var errorDescription: String? {
        switch self {
        case let .systemCall(name, code):
            return "PacketFlow bridge \(name) failed (errno \(code))"
        case .malformedBatch:
            return "PacketFlow returned mismatched packet/protocol arrays"
        case .malformedFrame:
            return "PacketFlow bridge received a malformed framed packet"
        case .packetWriteRejected:
            return "PacketFlow rejected packets emitted by the core"
        }
    }
}

 
enum PacketFlowFaultDisposition: Equatable {
     
    case transient
     
     
    case peerGone
}

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
struct PacketFlowFaultWindow: Equatable {
    static let defaultLimitNanoseconds: UInt64 = 10_000_000_000
    static let defaultMinimumFaults: UInt64 = 5

    let limitNanoseconds: UInt64
    let minimumFaults: UInt64
    private(set) var streakStartedAt: UInt64?
    private(set) var lastFaultAt: UInt64?
    private(set) var faultsInStreak: UInt64 = 0

    init(
        limitNanoseconds: UInt64 = PacketFlowFaultWindow.defaultLimitNanoseconds,
        minimumFaults: UInt64 = PacketFlowFaultWindow.defaultMinimumFaults
    ) {
        self.limitNanoseconds = limitNanoseconds
        self.minimumFaults = max(1, minimumFaults)
    }

     
     
    var limitDescription: String {
        limitNanoseconds % 1_000_000_000 == 0
            ? "\(limitNanoseconds / 1_000_000_000) s"
            : "\(limitNanoseconds / 1_000_000) ms"
    }

    mutating func recordSuccess() {
        guard streakStartedAt != nil else { return }
        streakStartedAt = nil
        lastFaultAt = nil
        faultsInStreak = 0
    }

     
     
     
     
    mutating func recordFault(at now: UInt64) -> Bool {
        if let last = lastFaultAt, now > last, now - last > limitNanoseconds {
            streakStartedAt = nil
            faultsInStreak = 0
        }
        let start = streakStartedAt ?? now
        streakStartedAt = start
        lastFaultAt = now
        faultsInStreak &+= 1
        return faultsInStreak >= minimumFaults && now >= start && now - start >= limitNanoseconds
    }
}

struct PacketFlowBridgeSnapshot: Equatable {
     
     
     
    let readCallbackBatches: UInt64
    let packetsFromSystem: UInt64
    let bytesFromSystem: UInt64
    let packetsToCore: UInt64
    let bytesToCore: UInt64
    let sendSyscallCount: UInt64
    let sendWouldBlockCount: UInt64
    let sendENOBUFSCount: UInt64
    let sendENOMEMCount: UInt64
    let receiveWouldBlockCount: UInt64
    let receiveENOBUFSCount: UInt64
    let receiveENOMEMCount: UInt64
    let sendBackoffCount: UInt64
     
     
    let sendAccumulatedBackoffNanoseconds: UInt64
    let receiveBackoffCount: UInt64
    let receiveAccumulatedBackoffNanoseconds: UInt64
    let packetsToSystem: UInt64
    let droppedToCore: UInt64
    let droppedToSystem: UInt64
     
    let packetWriteRejectedCount: UInt64
     
    let transientFaultCount: UInt64
    let pendingPackets: Int
    let pendingBytes: Int
    let peakPendingPackets: Int
    let peakPendingBytes: Int
    let queueLatencySamples: UInt64
    let averageQueueLatencyNanoseconds: UInt64
    let maxQueueLatencyNanoseconds: UInt64
    let systemWriteCalls: UInt64
    let maxSystemWriteBatch: Int
    let configuredMaxDrainBatch: Int
    let coreToSystemFlushNanoseconds: UInt64
    let socketBufferRequestedBytes: Int
    let flowEndpointSendBufferBytes: Int
    let flowEndpointReceiveBufferBytes: Int
    let coreEndpointSendBufferBytes: Int
    let coreEndpointReceiveBufferBytes: Int
    let flowEndpointSendBufferSetErrno: Int32
    let flowEndpointReceiveBufferSetErrno: Int32
    let coreEndpointSendBufferSetErrno: Int32
    let coreEndpointReceiveBufferSetErrno: Int32
    let flowEndpointSendBufferGetErrno: Int32
    let flowEndpointReceiveBufferGetErrno: Int32
    let coreEndpointSendBufferGetErrno: Int32
    let coreEndpointReceiveBufferGetErrno: Int32
}

struct PacketFlowBridgeConfiguration: Equatable {
    static let `default` = PacketFlowBridgeConfiguration()
    static let maxAllowedDrainBatch = 256
    static let maxAllowedFlushNanoseconds: UInt64 = 5_000_000

    let maxDrainBatch: Int
    let coreToSystemFlushNanoseconds: UInt64

    init() {
        maxDrainBatch = 64
        coreToSystemFlushNanoseconds = 0
    }

    init(validatingMaxDrainBatch maxDrainBatch: Int, coreToSystemFlushNanoseconds: UInt64) throws {
        guard (1...Self.maxAllowedDrainBatch).contains(maxDrainBatch) else {
            throw PacketFlowBridgeConfigurationError.invalidMaxDrainBatch(maxDrainBatch)
        }
        guard coreToSystemFlushNanoseconds <= Self.maxAllowedFlushNanoseconds else {
            throw PacketFlowBridgeConfigurationError.invalidFlushNanoseconds(
                coreToSystemFlushNanoseconds
            )
        }
        self.maxDrainBatch = maxDrainBatch
        self.coreToSystemFlushNanoseconds = coreToSystemFlushNanoseconds
    }
}

enum PacketFlowBridgeConfigurationError: LocalizedError {
    case invalidMaxDrainBatch(Int)
    case invalidFlushNanoseconds(UInt64)

    var errorDescription: String? {
        switch self {
        case let .invalidMaxDrainBatch(value):
            return "PacketFlow max drain batch must be 1...256, got \(value)"
        case let .invalidFlushNanoseconds(value):
            return "PacketFlow flush window must be 0...5000000 ns, got \(value)"
        }
    }
}

private struct PendingPacket {
    let frame: Data
    let enqueuedAt: UInt64
}

private struct PacketFlowSocketBufferOptionResult {
    let bytes: Int
    let setErrno: Int32
    let getErrno: Int32
}

private struct PacketFlowSocketBufferEndpointResult {
    static let unavailable = PacketFlowSocketBufferEndpointResult(
        send: PacketFlowSocketBufferOptionResult(bytes: -1, setErrno: 0, getErrno: 0),
        receive: PacketFlowSocketBufferOptionResult(bytes: -1, setErrno: 0, getErrno: 0)
    )

    let send: PacketFlowSocketBufferOptionResult
    let receive: PacketFlowSocketBufferOptionResult
}

 
 
 
private final class PacketFlowSourceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func sourceDidCancel() {
        lock.lock()
        remaining -= 1
        let shouldClose = remaining == 0
        let fd = descriptor
        if shouldClose { descriptor = -1 }
        lock.unlock()
        if shouldClose, fd >= 0 { Darwin.close(fd) }
    }
}

 
 
 
 
 
 
final class PacketFlowBridge: @unchecked Sendable {
    private static let headerSize = 4
    private static let maxIPPacketSize = 65_535
    private static let requestedSocketBufferBytes: Int32 = 1 * 1_024 * 1_024

    private let packetFlow: PacketFlowIO
    private let queue = DispatchQueue(label: "app.clash.adapter.packetflow")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let maxPendingPackets: Int
    private let maxPendingBytes: Int
    private let monotonicNanoseconds: @Sendable () -> UInt64
     
     
     
     
     
     
     
     
    private let sendToFlow: @Sendable (Int32, UnsafeRawPointer?, Int, Int32) -> (Int, Int32)
    private let recvFromFlow: @Sendable (Int32, UnsafeMutableRawPointer?, Int, Int32) -> (Int, Int32)
     
     
    private let scheduleFlushRetry: @Sendable (DispatchQueue, UInt64, @escaping @Sendable () -> Void) -> Void
    private let configuration: PacketFlowBridgeConfiguration
    private let onFailure: (Error) -> Void
     
     
     
    private let logLine: (String) -> Void
    private let log = Logger(subsystem: "app.clash.adapter", category: "packetflow")

    private var flowFileDescriptor: Int32 = -1
    private(set) var coreFileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var sourceCancellation: PacketFlowSourceCancellation?
    private var writeSourceIsResumed = false
     
     
     
     
     
    private var readSourceIsResumed = false
    private var flowReadOutstanding = false
    private var running = false
    private var didFail = false
    private var coreDrainScheduled = false
    private var coreDrainGeneration: UInt64 = 0
     
     
     
    private var drainBackoffScheduled = false
    private var flushBackoffScheduled = false
    private var consecutiveDrainPressure = 0
    private var consecutiveFlushPressure = 0
     
     
    private let faultWindow: PacketFlowFaultWindow
    private var uplinkFaults: PacketFlowFaultWindow
    private var downlinkFaults: PacketFlowFaultWindow
     
     
     
     
    private var coreDrainStorage = [UInt8](
        repeating: 0,
        count: PacketFlowBridge.maxIPPacketSize + PacketFlowBridge.headerSize
    )

    private var pendingToCore: [PendingPacket] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var peakPendingPackets = 0
    private var peakPendingBytes = 0

    private var readCallbackBatches: UInt64 = 0
    private var packetsFromSystem: UInt64 = 0
    private var bytesFromSystem: UInt64 = 0
    private var packetsToCore: UInt64 = 0
    private var bytesToCore: UInt64 = 0
    private var sendSyscallCount: UInt64 = 0
    private var sendWouldBlockCount: UInt64 = 0
    private var sendENOBUFSCount: UInt64 = 0
    private var sendENOMEMCount: UInt64 = 0
    private var receiveWouldBlockCount: UInt64 = 0
    private var receiveENOBUFSCount: UInt64 = 0
    private var receiveENOMEMCount: UInt64 = 0
    private var sendBackoffCount: UInt64 = 0
    private var sendAccumulatedBackoffNanoseconds: UInt64 = 0
    private var receiveBackoffCount: UInt64 = 0
    private var receiveAccumulatedBackoffNanoseconds: UInt64 = 0
    private var packetsToSystem: UInt64 = 0
    private var droppedToCore: UInt64 = 0
    private var droppedToSystem: UInt64 = 0
    private var packetWriteRejectedCount: UInt64 = 0
    private var transientFaultCount: UInt64 = 0
    private var queueLatencySamples: UInt64 = 0
    private var totalQueueLatencyNanoseconds: UInt64 = 0
    private var maxQueueLatencyNanoseconds: UInt64 = 0
    private var systemWriteCalls: UInt64 = 0
    private var maxSystemWriteBatch = 0
    private var flowEndpointSocketBuffers = PacketFlowSocketBufferEndpointResult.unavailable
    private var coreEndpointSocketBuffers = PacketFlowSocketBufferEndpointResult.unavailable

    init(
        packetFlow: PacketFlowIO,
        maxPendingPackets: Int = 1_024,
        maxPendingBytes: Int = 4 * 1_024 * 1_024,
        configuration: PacketFlowBridgeConfiguration = .default,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sendToFlow: @escaping @Sendable (Int32, UnsafeRawPointer?, Int, Int32) -> (Int, Int32) = { fd, buffer, length, flags in
            let result = Darwin.send(fd, buffer, length, flags)
            return (result, result < 0 ? errno : 0)
        },
        recvFromFlow: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int, Int32) -> (Int, Int32) = { fd, buffer, length, flags in
            let result = Darwin.recv(fd, buffer, length, flags)
            return (result, result < 0 ? errno : 0)
        },
        scheduleFlushRetry: @escaping @Sendable (DispatchQueue, UInt64, @escaping @Sendable () -> Void) -> Void = { queue, delay, retry in
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: retry)
        },
        faultWindow: PacketFlowFaultWindow = PacketFlowFaultWindow(),
        logLine: @escaping (String) -> Void = { _ in },
        onFailure: @escaping (Error) -> Void
    ) {
        self.faultWindow = faultWindow
        self.uplinkFaults = faultWindow
        self.downlinkFaults = faultWindow
        self.packetFlow = packetFlow
        self.maxPendingPackets = max(1, maxPendingPackets)
        self.maxPendingBytes = max(4_096, maxPendingBytes)
        self.configuration = configuration
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sendToFlow = sendToFlow
        self.recvFromFlow = recvFromFlow
        self.scheduleFlushRetry = scheduleFlushRetry
        self.logLine = logLine
        self.onFailure = onFailure
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() throws -> Int32 {
        try syncOnQueue {
            guard !running else { return coreFileDescriptor }

            var descriptors = [Int32](repeating: -1, count: 2)
            let socketResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                socketpair(AF_UNIX, SOCK_DGRAM, 0, buffer.baseAddress!)
            }
            guard socketResult == 0 else {
                throw PacketFlowBridgeError.systemCall("socketpair", errno)
            }

            flowFileDescriptor = descriptors[0]
            coreFileDescriptor = descriptors[1]
            flowEndpointSocketBuffers = .unavailable
            coreEndpointSocketBuffers = .unavailable
            do {
                flowEndpointSocketBuffers = try configureDescriptor(flowFileDescriptor)
                coreEndpointSocketBuffers = try configureDescriptor(coreFileDescriptor)
            } catch {
                closeDescriptor(&flowFileDescriptor)
                closeDescriptor(&coreFileDescriptor)
                throw error
            }

            running = true
            didFail = false
            coreDrainGeneration &+= 1
            installSources()
            scheduleFlowRead()
            log.info("public PacketFlow bridge started")
            return coreFileDescriptor
        }
    }

    func stop() {
        syncOnQueue {
            teardown()
        }
    }

    func snapshot() -> PacketFlowBridgeSnapshot {
        syncOnQueue {
            PacketFlowBridgeSnapshot(
                readCallbackBatches: readCallbackBatches,
                packetsFromSystem: packetsFromSystem,
                bytesFromSystem: bytesFromSystem,
                packetsToCore: packetsToCore,
                bytesToCore: bytesToCore,
                sendSyscallCount: sendSyscallCount,
                sendWouldBlockCount: sendWouldBlockCount,
                sendENOBUFSCount: sendENOBUFSCount,
                sendENOMEMCount: sendENOMEMCount,
                receiveWouldBlockCount: receiveWouldBlockCount,
                receiveENOBUFSCount: receiveENOBUFSCount,
                receiveENOMEMCount: receiveENOMEMCount,
                sendBackoffCount: sendBackoffCount,
                sendAccumulatedBackoffNanoseconds: sendAccumulatedBackoffNanoseconds,
                receiveBackoffCount: receiveBackoffCount,
                receiveAccumulatedBackoffNanoseconds: receiveAccumulatedBackoffNanoseconds,
                packetsToSystem: packetsToSystem,
                droppedToCore: droppedToCore,
                droppedToSystem: droppedToSystem,
                packetWriteRejectedCount: packetWriteRejectedCount,
                transientFaultCount: transientFaultCount,
                pendingPackets: pendingToCore.count - pendingHead,
                pendingBytes: pendingBytes,
                peakPendingPackets: peakPendingPackets,
                peakPendingBytes: peakPendingBytes,
                queueLatencySamples: queueLatencySamples,
                averageQueueLatencyNanoseconds: queueLatencySamples == 0
                    ? 0
                    : totalQueueLatencyNanoseconds / queueLatencySamples,
                maxQueueLatencyNanoseconds: maxQueueLatencyNanoseconds,
                systemWriteCalls: systemWriteCalls,
                maxSystemWriteBatch: maxSystemWriteBatch,
                configuredMaxDrainBatch: configuration.maxDrainBatch,
                coreToSystemFlushNanoseconds: configuration.coreToSystemFlushNanoseconds,
                socketBufferRequestedBytes: Int(Self.requestedSocketBufferBytes),
                flowEndpointSendBufferBytes: flowEndpointSocketBuffers.send.bytes,
                flowEndpointReceiveBufferBytes: flowEndpointSocketBuffers.receive.bytes,
                coreEndpointSendBufferBytes: coreEndpointSocketBuffers.send.bytes,
                coreEndpointReceiveBufferBytes: coreEndpointSocketBuffers.receive.bytes,
                flowEndpointSendBufferSetErrno: flowEndpointSocketBuffers.send.setErrno,
                flowEndpointReceiveBufferSetErrno: flowEndpointSocketBuffers.receive.setErrno,
                coreEndpointSendBufferSetErrno: coreEndpointSocketBuffers.send.setErrno,
                coreEndpointReceiveBufferSetErrno: coreEndpointSocketBuffers.receive.setErrno,
                flowEndpointSendBufferGetErrno: flowEndpointSocketBuffers.send.getErrno,
                flowEndpointReceiveBufferGetErrno: flowEndpointSocketBuffers.receive.getErrno,
                coreEndpointSendBufferGetErrno: coreEndpointSocketBuffers.send.getErrno,
                coreEndpointReceiveBufferGetErrno: coreEndpointSocketBuffers.receive.getErrno
            )
        }
    }

    private func configureDescriptor(
        _ descriptor: Int32
    ) throws -> PacketFlowSocketBufferEndpointResult {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw PacketFlowBridgeError.systemCall("fcntl(O_NONBLOCK)", errno)
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw PacketFlowBridgeError.systemCall("fcntl(FD_CLOEXEC)", errno)
        }
         
         
         
        let receive = configureSocketBuffer(descriptor, option: SO_RCVBUF)
        let send = configureSocketBuffer(descriptor, option: SO_SNDBUF)
        return PacketFlowSocketBufferEndpointResult(send: send, receive: receive)
    }

    private func configureSocketBuffer(
        _ descriptor: Int32,
        option: Int32
    ) -> PacketFlowSocketBufferOptionResult {
        var requested = Self.requestedSocketBufferBytes
        let setResult = setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &requested,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let setErrno = setResult == 0 ? 0 : errno
        var confirmed: Int32 = 0
        var confirmedLength = socklen_t(MemoryLayout<Int32>.size)
        let getResult = getsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &confirmed,
            &confirmedLength
        )
        let getErrno = getResult == 0 ? 0 : errno
        return PacketFlowSocketBufferOptionResult(
            bytes: getResult == 0 ? Int(confirmed) : -1,
            setErrno: setErrno,
            getErrno: getErrno
        )
    }

    private func installSources() {
        let cancellation = PacketFlowSourceCancellation(descriptor: flowFileDescriptor)
        sourceCancellation = cancellation
        let readSource = DispatchSource.makeReadSource(fileDescriptor: flowFileDescriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.scheduleCoreDrain()
        }
        readSource.setCancelHandler {
            cancellation.sourceDidCancel()
        }
        self.readSource = readSource
        readSource.resume()
        readSourceIsResumed = true

        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: flowFileDescriptor, queue: queue)
        writeSource.setEventHandler { [weak self] in
            self?.flushPendingToCore()
        }
        writeSource.setCancelHandler {
            cancellation.sourceDidCancel()
        }
        self.writeSource = writeSource
    }

    private func scheduleFlowRead() {
        guard running, !flowReadOutstanding else { return }
        flowReadOutstanding = true
        let generation = coreDrainGeneration
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                 
                 
                guard self.running, self.coreDrainGeneration == generation else { return }
                self.flowReadOutstanding = false
                self.readCallbackBatches &+= 1
                self.packetsFromSystem &+= UInt64(packets.count)
                for packet in packets {
                    self.bytesFromSystem &+= UInt64(packet.count)
                }
                guard packets.count == protocols.count else {
                     
                    self.droppedToCore &+= UInt64(packets.count)
                    guard self.noteTransientFault(
                        .malformedBatch, direction: .toCore, dropped: packets.count
                    ) else { return }
                    self.scheduleFlowRead()
                    return
                }
                for (packet, proto) in zip(packets, protocols) {
                    self.enqueueToCore(Self.frame(packet: packet, protocolFamily: proto.int32Value))
                }
                self.flushPendingToCore()
                self.scheduleFlowRead()
            }
        }
    }

    private func enqueueToCore(_ frame: Data) {
        let count = pendingToCore.count - pendingHead
        guard count < maxPendingPackets, pendingBytes + frame.count <= maxPendingBytes else {
            droppedToCore += 1
            return
        }
        pendingToCore.append(PendingPacket(frame: frame, enqueuedAt: monotonicNanoseconds()))
        pendingBytes += frame.count
        peakPendingPackets = max(peakPendingPackets, count + 1)
        peakPendingBytes = max(peakPendingBytes, pendingBytes)
    }

    private func flushPendingToCore() {
         
         
        guard running, !flushBackoffScheduled else { return }
         
         
        var sentAny = false
        while pendingHead < pendingToCore.count {
            let pending = pendingToCore[pendingHead]
            let (sent, sendErrno) = pending.frame.withUnsafeBytes { bytes in
                sendToFlow(flowFileDescriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
            }
            sendSyscallCount &+= 1
            if sent == pending.frame.count {
                pendingBytes -= pending.frame.count
                pendingHead += 1
                packetsToCore &+= 1
                bytesToCore &+= UInt64(pending.frame.count - Self.headerSize)
                recordQueueLatency(since: pending.enqueuedAt)
                uplinkFaults.recordSuccess()
                sentAny = true
                continue
            }
            if sent < 0, sendErrno == EINTR {
                continue
            }
            if sent < 0, Self.isWouldBlockErrno(sendErrno) {
                sendWouldBlockCount &+= 1
                 
                 
                consecutiveFlushPressure = 0
                compactPendingQueueIfNeeded()
                resumeWriteSourceIfNeeded()
                return
            }
            if sent < 0, Self.isResourcePressureErrno(sendErrno) {
                if sendErrno == ENOBUFS {
                    sendENOBUFSCount &+= 1
                } else {
                    sendENOMEMCount &+= 1
                }
                 
                 
                 
                compactPendingQueueIfNeeded()
                scheduleFlushBackoff()
                return
            }
            let error = PacketFlowBridgeError.systemCall("send", sendErrno)
            if Self.faultDisposition(forErrno: sendErrno) == .peerGone {
                fail(error, reason: Self.peerGoneReason)
                return
            }
             
             
             
             
            pendingBytes -= pending.frame.count
            pendingHead += 1
            droppedToCore &+= 1
            compactPendingQueueIfNeeded()
            guard noteTransientFault(error, direction: .toCore, dropped: 1) else { return }
            scheduleFlushBackoff()
            return
        }
        pendingToCore.removeAll(keepingCapacity: true)
        pendingHead = 0
        pendingBytes = 0
        if sentAny {
            consecutiveFlushPressure = 0
        }
        suspendWriteSourceIfNeeded()
    }

    private func compactPendingQueueIfNeeded() {
        guard pendingHead > 0,
              pendingHead >= 256 || pendingHead * 2 >= pendingToCore.count
        else { return }
        pendingToCore.removeFirst(pendingHead)
        pendingHead = 0
    }

    private func recordQueueLatency(since enqueuedAt: UInt64) {
        let now = monotonicNanoseconds()
        let latency = now >= enqueuedAt ? now - enqueuedAt : 0
        queueLatencySamples &+= 1
        let (total, overflow) = totalQueueLatencyNanoseconds.addingReportingOverflow(latency)
        totalQueueLatencyNanoseconds = overflow ? UInt64.max : total
        maxQueueLatencyNanoseconds = max(maxQueueLatencyNanoseconds, latency)
    }

    private func scheduleCoreDrain() {
        guard running, !coreDrainScheduled else { return }
        coreDrainScheduled = true
        let generation = coreDrainGeneration
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.coreDrainGeneration == generation else { return }
                self.coreDrainScheduled = false
                if self.drainCorePackets() {
                    self.scheduleCoreDrain()
                }
            }
        }
        if configuration.coreToSystemFlushNanoseconds == 0 {
            work()
        } else {
            queue.asyncAfter(
                deadline: .now() + .nanoseconds(Int(configuration.coreToSystemFlushNanoseconds)),
                execute: work
            )
        }
    }

     
     
     
     
     
     
     
    private func drainCorePackets() -> Bool {
        guard running else { return false }
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        var resourcePressure = false

        for _ in 0..<configuration.maxDrainBatch {
            let (received, recvErrno) = coreDrainStorage.withUnsafeMutableBytes { bytes in
                recvFromFlow(flowFileDescriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
            }
            if received < 0, recvErrno == EINTR {
                continue
            }
            if received < 0, Self.isWouldBlockErrno(recvErrno) {
                receiveWouldBlockCount &+= 1
                 
                 
                consecutiveDrainPressure = 0
                break
            }
            if received < 0, Self.isResourcePressureErrno(recvErrno) {
                if recvErrno == ENOBUFS {
                    receiveENOBUFSCount &+= 1
                } else {
                    receiveENOMEMCount &+= 1
                }
                 
                 
                 
                resourcePressure = true
                break
            }
            if received < 0 {
                let error = PacketFlowBridgeError.systemCall("recv", recvErrno)
                if Self.faultDisposition(forErrno: recvErrno) == .peerGone {
                    fail(error, reason: Self.peerGoneReason)
                    return false
                }
                 
                 
                 
                guard noteTransientFault(error, direction: .toSystem, dropped: 0) else { return false }
                resourcePressure = true
                break
            }
            guard received >= Self.headerSize else {
                droppedToSystem += 1
                continue
            }
             
             
             
             
            let decoded: (packet: Data, protocolFamily: Int32)? = coreDrainStorage.withUnsafeBytes { raw in
                guard let family = Self.protocolFamily(fromHeader: raw) else { return nil }
                let payload = Data(
                    bytes: raw.baseAddress!.advanced(by: Self.headerSize),
                    count: received - Self.headerSize
                )
                return (payload, family)
            }
            guard let decoded else {
                droppedToSystem += 1
                continue
            }
            packets.append(decoded.packet)
            protocols.append(NSNumber(value: decoded.protocolFamily))
        }

        if !packets.isEmpty {
            guard packetFlow.writePackets(packets, withProtocols: protocols) else {
                 
                 
                 
                droppedToSystem += UInt64(packets.count)
                packetWriteRejectedCount &+= 1
                guard noteTransientFault(
                    .packetWriteRejected, direction: .toSystem, dropped: packets.count
                ) else { return false }
                scheduleDrainBackoff()
                return false
            }
            downlinkFaults.recordSuccess()
            packetsToSystem += UInt64(packets.count)
            systemWriteCalls &+= 1
            maxSystemWriteBatch = max(maxSystemWriteBatch, packets.count)
        }

        if resourcePressure {
             
             
            scheduleDrainBackoff()
            return false
        }
        return !packets.isEmpty && packets.count == configuration.maxDrainBatch
    }

    private func resumeWriteSourceIfNeeded() {
        guard let writeSource, !writeSourceIsResumed else { return }
        writeSourceIsResumed = true
        writeSource.resume()
    }

    private func suspendWriteSourceIfNeeded() {
        guard let writeSource, writeSourceIsResumed else { return }
        writeSource.suspend()
        writeSourceIsResumed = false
    }

    private func resumeReadSourceIfNeeded() {
        guard let readSource, !readSourceIsResumed else { return }
        readSourceIsResumed = true
        readSource.resume()
    }

    private func suspendReadSourceIfNeeded() {
        guard let readSource, readSourceIsResumed else { return }
        readSource.suspend()
        readSourceIsResumed = false
    }

     
     
     
     
    private static let resourceBackoffBaseNanoseconds: UInt64 = 1_000_000
    private static let resourceBackoffMaxNanoseconds: UInt64 = 64_000_000

    private func resourceBackoffNanoseconds(_ consecutive: Int) -> UInt64 {
        let shift = UInt64(min(max(consecutive - 1, 0), 6))
        return min(Self.resourceBackoffMaxNanoseconds, Self.resourceBackoffBaseNanoseconds << shift)
    }

     
     
     
    private func scheduleDrainBackoff() {
        suspendReadSourceIfNeeded()
        guard !drainBackoffScheduled else { return }
        drainBackoffScheduled = true
        consecutiveDrainPressure += 1
        let generation = coreDrainGeneration
        let delay = resourceBackoffNanoseconds(consecutiveDrainPressure)
        receiveBackoffCount &+= 1
        receiveAccumulatedBackoffNanoseconds &+= delay
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            guard let self, self.running, self.coreDrainGeneration == generation else { return }
            self.drainBackoffScheduled = false
            self.resumeReadSourceIfNeeded()
            self.scheduleCoreDrain()
        }
    }

     
     
     
    private func scheduleFlushBackoff() {
        suspendWriteSourceIfNeeded()
        guard !flushBackoffScheduled else { return }
        flushBackoffScheduled = true
        consecutiveFlushPressure += 1
        let generation = coreDrainGeneration
        let delay = resourceBackoffNanoseconds(consecutiveFlushPressure)
        sendBackoffCount &+= 1
        sendAccumulatedBackoffNanoseconds &+= delay
        scheduleFlushRetry(queue, delay) { [weak self] in
            guard let self, self.running, self.coreDrainGeneration == generation else { return }
            self.flushBackoffScheduled = false
            self.flushPendingToCore()
        }
    }

    private enum Direction: String {
        case toCore = "to the core"
        case toSystem = "to the system"
    }

    static let peerGoneReason = "the core's end of the socket is closed"

     
     
     
    private func noteTransientFault(_ error: PacketFlowBridgeError, direction: Direction, dropped: Int) -> Bool {
        transientFaultCount &+= 1
        let now = monotonicNanoseconds()
        let sustained: Bool
        let streak: UInt64
        switch direction {
        case .toCore:
            sustained = uplinkFaults.recordFault(at: now)
            streak = uplinkFaults.faultsInStreak
        case .toSystem:
            sustained = downlinkFaults.recordFault(at: now)
            streak = downlinkFaults.faultsInStreak
        }
        if sustained {
            fail(error, reason: "no packet got through \(direction.rawValue) for \(faultWindow.limitDescription) (\(streak) faults in a row)")
            return false
        }
        if Self.logsTransientFault(occurrence: transientFaultCount) {
            logLine(
                "PacketFlow bridge: \(error.localizedDescription); dropped \(dropped) packet(s) going "
                    + "\(direction.rawValue), the tunnel stays up (fault \(transientFaultCount))"
            )
        }
        return true
    }

    private func fail(_ error: Error, reason: String) {
        guard !didFail else { return }
        didFail = true
        log.error("PacketFlow bridge failed: \(error.localizedDescription, privacy: .private)")
        logLine("PacketFlow bridge failed: \(error.localizedDescription); \(reason)")
        teardown()
        onFailure(error)
    }

     
     
     
    static func faultDisposition(forErrno code: Int32) -> PacketFlowFaultDisposition {
        switch code {
        case EPIPE, ECONNRESET, ENOTCONN, EBADF, ECONNREFUSED, ENOTSOCK, ESHUTDOWN:
            return .peerGone
        default:
            return .transient
        }
    }

     
     
    static func logsTransientFault(occurrence: UInt64) -> Bool {
        guard occurrence > 0 else { return false }
        var remaining = occurrence
        while remaining % 10 == 0 { remaining /= 10 }
        return remaining == 1
    }

    private func teardown() {
        running = false
        coreDrainGeneration &+= 1
        coreDrainScheduled = false
        drainBackoffScheduled = false
        flushBackoffScheduled = false
        consecutiveDrainPressure = 0
        consecutiveFlushPressure = 0
        uplinkFaults = faultWindow
        downlinkFaults = faultWindow
        flowReadOutstanding = false
        pendingToCore.removeAll(keepingCapacity: false)
        pendingHead = 0
        pendingBytes = 0

        if let writeSource {
            if !writeSourceIsResumed {
                writeSource.resume()
            }
            writeSource.cancel()
            self.writeSource = nil
            writeSourceIsResumed = false
        }
        if let readSource {
             
             
            if !readSourceIsResumed {
                readSource.resume()
            }
            readSource.cancel()
            self.readSource = nil
            readSourceIsResumed = false
        }

         
         
        flowFileDescriptor = -1
        sourceCancellation = nil
        closeDescriptor(&coreFileDescriptor)
    }

    private func closeDescriptor(_ descriptor: inout Int32) {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

     
     
     
     
     
    static func isWouldBlockErrno(_ code: Int32) -> Bool {
        return code == EAGAIN || code == EWOULDBLOCK
    }

     
     
     
     
     
     
     
     
     
    static func isResourcePressureErrno(_ code: Int32) -> Bool {
        return code == ENOBUFS || code == ENOMEM
    }

     
     
    static func isTransientFlowErrno(_ code: Int32) -> Bool {
        return isWouldBlockErrno(code) || isResourcePressureErrno(code)
    }

    static func frame(packet: Data, protocolFamily: Int32) -> Data {
        var family = UInt32(bitPattern: protocolFamily).bigEndian
        var framed = Data(bytes: &family, count: headerSize)
        framed.append(packet)
        return framed
    }

     
     
     
     
    static func protocolFamily(fromHeader header: UnsafeRawBufferPointer) -> Int32? {
        guard header.count >= headerSize else { return nil }
        var rawFamily: UInt32 = 0
        withUnsafeMutableBytes(of: &rawFamily) { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: header[0..<headerSize]))
        }
        let family = Int32(bitPattern: UInt32(bigEndian: rawFamily))
        return (family == AF_INET || family == AF_INET6) ? family : nil
    }

    static func decode(frame: Data) -> (packet: Data, protocolFamily: Int32)? {
        guard frame.count >= headerSize,
              let family = frame.withUnsafeBytes({ protocolFamily(fromHeader: $0) })
        else {
            return nil
        }
        return (Data(frame.dropFirst(headerSize)), family)
    }
}

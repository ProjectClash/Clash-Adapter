import Darwin
import Foundation
import Network
import NetworkExtension

enum ProviderLifecycleState: String, Equatable {
    case idle
    case starting
    case running
    case stopping
    case failed
}

enum ProviderLifecycleError: LocalizedError {
    case invalidTransition(from: ProviderLifecycleState, operation: String)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(state, operation):
            return "cannot \(operation) packet tunnel while lifecycle is \(state.rawValue)"
        }
    }
}

 
 
 
 
 
enum ProviderTeardownPolicy {
    case failedStart
    case inProcessRestart
    case systemStop

    var clearsNetworkSettings: Bool {
        self == .failedStart
    }
}

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
func hakoStopReasonSummary(_ reason: NEProviderStopReason) -> String {
    let meaning: String
    switch reason {
    case .none: meaning = "none"
    case .userInitiated: meaning = "user-initiated"
    case .providerFailed: meaning = "provider-failed"
    case .noNetworkAvailable: meaning = "no-network-available"
    case .unrecoverableNetworkChange: meaning = "unrecoverable-network-change"
    case .providerDisabled: meaning = "provider-disabled"
    case .authenticationCanceled: meaning = "authentication-canceled"
    case .configurationFailed: meaning = "configuration-failed"
    case .idleTimeout: meaning = "idle-timeout"
    case .configurationDisabled: meaning = "configuration-disabled"
    case .configurationRemoved: meaning = "configuration-removed"
    case .superceded: meaning = "superceded"
    case .userLogout: meaning = "user-logout"
    case .userSwitch: meaning = "user-switch"
    case .connectionFailed: meaning = "connection-failed"
    case .sleep: meaning = "sleep"
    case .appUpdate: meaning = "app-update"
    case .internalError: meaning = "internal-error"
    @unknown default: meaning = "unrecognized"
    }
    return "\(meaning) (reason=\(reason.rawValue))"
}

 
 
 
final class ProviderLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProviderLifecycleState = .idle

    var state: ProviderLifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func beginStart() throws {
        lock.lock()
        defer { lock.unlock() }
        guard value == .idle || value == .failed else {
            throw ProviderLifecycleError.invalidTransition(from: value, operation: "start")
        }
        value = .starting
    }

    func didStart() throws {
        lock.lock()
        defer { lock.unlock() }
        guard value == .starting else {
            throw ProviderLifecycleError.invalidTransition(from: value, operation: "complete start")
        }
        value = .running
    }

    func didFailStart() {
        lock.lock()
        defer { lock.unlock() }
        if value == .starting {
            value = .failed
        }
    }

     
    func beginStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != .idle, value != .stopping else { return false }
        value = .stopping
        return true
    }

    func didStop() {
        lock.lock()
        value = .idle
        lock.unlock()
    }
}

 
 
 
actor ProviderOperationGate {
    private var isEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard isEntered else {
            isEntered = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        guard !waiters.isEmpty else {
            isEntered = false
            return
        }
        waiters.removeFirst().resume()
    }
}

 
 
 
final class ProviderTunnelSessionLease: @unchecked Sendable {
     
     
    struct Session: Equatable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var issued: UInt64 = 0
    private var current: UInt64?
     
     
     
    private var owesCompensation = false

     
    func begin() -> Session {
        lock.lock()
        defer { lock.unlock() }
        issued &+= 1
        current = issued
        return Session(generation: issued)
    }

     
     
     
    func invalidate(ifCurrent session: Session? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let session, current != session.generation { return }
        if current != nil { owesCompensation = true }
        current = nil
    }

     
     
     
     
    @discardableResult
    func commitIfCurrent(_ session: Session, _ commit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == session.generation else { return false }
        commit()
        return true
    }

     
     
     
     
     
     
     
     
     
    @discardableResult
    func compensateIfIdle(_ compensate: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == nil, owesCompensation else { return false }
        owesCompensation = false
        compensate()
        return true
    }
}

 
 
 
final class ProviderReloadEnvelope: @unchecked Sendable {
     
     
     
     
     
     
     
    struct Status: Equatable {
        enum State: String, Equatable {
            case idle
            case applying
            case ok
            case failed
            case unknown
        }

        let session: String
        let ticket: Int
        let state: State
        let error: String?
         
         
         
        var errorClass: String? = nil
        var warning: String? = nil

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["session": session, "ticket": ticket, "state": state.rawValue]
            if let error { object["error"] = error }
            if let errorClass { object["errorClass"] = errorClass }
            if let warning { object["warning"] = warning }
            return object
        }
    }

     
     
    struct Verdict: Equatable {
        let errorClass: String
        let message: String

        static let succeeded = Verdict(errorClass: "", message: "")
    }

     
     
     
     
     
     
     
     
     
     
     
    struct Reply {
        let object: [String: Any]
        let start: (() -> Void)?
    }

     
     
    private final class Start {
        private let lock = NSLock()
        private var started = false
        private let envelope: ProviderReloadEnvelope
        private let ticket: Int
        private let apply: () throws -> Verdict

        init(envelope: ProviderReloadEnvelope, ticket: Int, apply: @escaping () throws -> Verdict) {
            self.envelope = envelope
            self.ticket = ticket
            self.apply = apply
        }

        func run() {
            lock.lock()
            guard !started else {
                lock.unlock()
                return
            }
            started = true
            lock.unlock()
            let envelope = self.envelope
            let ticket = self.ticket
            let apply = self.apply
            Task.detached(priority: .userInitiated) {
                envelope.finish(ticket, envelope.run(apply))
            }
        }

        deinit {
            lock.lock()
            let unstarted = !started
            lock.unlock()
            if unstarted {
                envelope.finish(ticket, Outcome(error: "clash: reload was accepted but never started", errorClass: "unknown"))
            }
        }
    }

    static let capability = "reload-async-v1"

    private let lock = NSLock()
     
     
    private let session = UUID().uuidString
    private var nextTicket = 0
    private var inFlight: Set<Int> = []
     
     
     
    private var synchronousRunning = 0
     
     
     
    private var outcomes: [Int: Status] = [:]
    private static let outcomesKept = 16

     
     
     
     
    func reply(
        to request: [String: Any],
        apply: @escaping () throws -> Void
    ) -> Reply {
        replyClassified(to: request, apply: { try apply(); return .succeeded })
    }

     
     
     
    func replyClassified(
        to request: [String: Any],
        apply: @escaping () throws -> Verdict
    ) -> Reply {
        let asynchronous = Self.isJSONTrue(request["async"])
        lock.lock()
        guard asynchronous else {
            synchronousRunning += 1
            lock.unlock()
            let outcome = run(apply)
            lock.lock()
            synchronousRunning -= 1
            lock.unlock()
            if let error = outcome.error {
                var object: [String: Any] = ["error": error]
                if let errorClass = outcome.errorClass { object["errorClass"] = errorClass }
                return Reply(object: object, start: nil)
            }
            var object: [String: Any] = ["ok": true]
            if let warning = outcome.warning {
                object["errorClass"] = "committed"
                object["warning"] = warning
            }
            return Reply(object: object, start: nil)
        }
        if !inFlight.isEmpty || synchronousRunning > 0 {
             
             
             
             
             
             
            var refusal: [String: Any] = ["error": "reload in progress"]
            if let running = inFlight.max() {
                refusal["ticket"] = running
            }
            lock.unlock()
            return Reply(object: refusal, start: nil)
        }
        nextTicket += 1
        let ticket = nextTicket
        inFlight.insert(ticket)
        lock.unlock()
        let start = Start(envelope: self, ticket: ticket, apply: apply)
        return Reply(
            object: ["accepted": true, "ticket": ticket, "session": session],
            start: { start.run() }
        )
    }

     
     
     
     
    func statusReply(to request: [String: Any]) -> [String: Any] {
        guard let field = request["ticket"] else {
            return status().jsonObject
        }
        guard let number = field as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let ticket = Int(exactly: number)
        else {
            return ["error": "bad ticket"]
        }
        return status(ticket: ticket).jsonObject
    }

     
     
     
     
     
    private static func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

     
     
     
     
     
     
    func status(ticket requested: Int? = nil) -> Status {
        lock.lock()
        defer { lock.unlock() }
        guard let ticket = requested else {
            if nextTicket == 0 {
                return Status(session: session, ticket: 0, state: .idle, error: nil)
            }
            return statusLocked(of: nextTicket)
        }
        return statusLocked(of: ticket)
    }

     
    private func statusLocked(of ticket: Int) -> Status {
        if ticket >= 1, inFlight.contains(ticket) {
            return Status(session: session, ticket: ticket, state: .applying, error: nil)
        }
        return outcomes[ticket] ?? Status(session: session, ticket: ticket, state: .unknown, error: nil)
    }

    private struct Outcome {
        let error: String?
        var errorClass: String? = nil
        var warning: String? = nil
    }

    private func run(_ apply: () throws -> Verdict) -> Outcome {
        do {
            let verdict = try apply()
            switch verdict.errorClass {
            case "":
                return Outcome(error: nil)
            case "committed":
                return Outcome(error: nil, warning: verdict.message)
            default:
                return Outcome(error: verdict.message, errorClass: verdict.errorClass)
            }
        } catch {
            return Outcome(error: error.localizedDescription)
        }
    }

    private func finish(_ ticket: Int, _ outcome: Outcome) {
        lock.lock()
        inFlight.remove(ticket)
        outcomes[ticket] = Status(
            session: session,
            ticket: ticket,
            state: outcome.error == nil ? .ok : .failed,
            error: outcome.error,
            errorClass: outcome.warning != nil ? "committed" : outcome.errorClass,
            warning: outcome.warning
        )
        while outcomes.count > Self.outcomesKept, let oldest = outcomes.keys.min() {
            outcomes.removeValue(forKey: oldest)
        }
        lock.unlock()
    }
}


struct PhysicalPathSnapshot: Equatable, Sendable {
    let interfaceName: String
    let interfaceType: String
    let interfaceIndex: UInt32
    let satisfied: Bool
    let expensive: Bool
    let constrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
     
     
     
    var availableInterfaces: [PhysicalInterfaceInventory.PathInterface] = []

    var isReady: Bool {
        satisfied && interfaceIndex != 0 && !interfaceName.isEmpty
    }
}

protocol PhysicalPathMonitoring: AnyObject {
    var updateHandler: ((PhysicalPathSnapshot) -> Void)? { get set }
     
     
     
     
    var currentPhysicalInterface: NWInterface? { get }
    func start(queue: DispatchQueue)
    func cancel()
}

extension PhysicalPathMonitoring {
    var currentPhysicalInterface: NWInterface? { nil }
}

final class ApplePhysicalPathMonitor: PhysicalPathMonitoring {
    private let monitor: NWPathMonitor
    private let logHandler: ((String) -> Void)?
    private let handlerLock = NSLock()
    private var handler: ((PhysicalPathSnapshot) -> Void)?
    private var physicalInterface: NWInterface?

    var updateHandler: ((PhysicalPathSnapshot) -> Void)? {
        get {
            handlerLock.lock(); defer { handlerLock.unlock() }
            return handler
        }
        set {
            handlerLock.lock()
            handler = newValue
            handlerLock.unlock()
        }
    }

    var currentPhysicalInterface: NWInterface? {
        handlerLock.lock(); defer { handlerLock.unlock() }
        return physicalInterface
    }

    init(requiredInterfaceType: NWInterface.InterfaceType? = nil, logHandler: ((String) -> Void)? = nil) {
        self.logHandler = logHandler
        if let requiredInterfaceType {
            monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
        } else {
            monitor = NWPathMonitor()
        }
    }

    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isSatisfied = path.status == .satisfied
             
             
             
            let interface = isSatisfied ? path.availableInterfaces.first {
                $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet
            } : nil
            handlerLock.lock()
            physicalInterface = interface
            handlerLock.unlock()
            let index = interface.map { if_nametoindex($0.name) } ?? 0
            let snapshot = PhysicalPathSnapshot(
                interfaceName: interface?.name ?? "",
                interfaceType: Self.interfaceTypeName(interface?.type),
                interfaceIndex: index,
                satisfied: isSatisfied && index != 0,
                expensive: path.isExpensive,
                constrained: path.isConstrained,
                supportsIPv4: path.supportsIPv4,
                supportsIPv6: path.supportsIPv6,
                availableInterfaces: path.availableInterfaces.map {
                    PhysicalInterfaceInventory.PathInterface(
                        name: $0.name, index: UInt32(clamping: $0.index), type: .init($0.type)
                    )
                }
            )
            logHandler?(
                "path facts: status=\(Self.statusName(path))"
                    + " interfaces=[\(path.availableInterfaces.map { "\($0.name)/\(Self.interfaceTypeName($0.type))" }.joined(separator: " "))]"
                    + " chose=\(interface?.name ?? "none") index=\(index)"
                    + " expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
                    + " v4=\(path.supportsIPv4) v6=\(path.supportsIPv6)"
            )
            updateHandler?(snapshot)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        updateHandler = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

     
     
     
    private static func statusName(_ path: Network.NWPath) -> String {
        switch path.status {
        case .satisfied: return "satisfied"
        case .requiresConnection: return "requiresConnection"
        case .unsatisfied: return "unsatisfied(\(unsatisfiedReasonName(path)))"
        @unknown default: return "unknown"
        }
    }

    private static func unsatisfiedReasonName(_ path: Network.NWPath) -> String {
        switch path.unsatisfiedReason {
        case .notAvailable: return "notAvailable"
        case .cellularDenied: return "cellularDenied"
        case .wifiDenied: return "wifiDenied"
        case .localNetworkDenied: return "localNetworkDenied"
        case .vpnInactive: return "vpnInactive"
        @unknown default: return "unknown"
        }
    }

    private static func interfaceTypeName(_ type: NWInterface.InterfaceType?) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wiredEthernet"
        case .loopback: return "loopback"
        case .other: return "other"
        case nil: return "none"
        @unknown default: return "unknown"
        }
    }
}

 
enum PhysicalInterfaceInventory {
    enum Kind: Int32 {
        case other = 0
        case wifi = 1
        case cellular = 2
        case wired = 3
        case loopback = 4
        case tunnel = 5

        init(_ type: NWInterface.InterfaceType) {
            switch type {
            case .wifi: self = .wifi
            case .cellular: self = .cellular
            case .wiredEthernet: self = .wired
            case .loopback: self = .loopback
            case .other: self = .other
            @unknown default: self = .other
            }
        }
    }

    struct Flags: OptionSet, Equatable {
        let rawValue: Int32
         
        static let up = Flags(rawValue: 1)
        static let broadcast = Flags(rawValue: 2)
        static let loopback = Flags(rawValue: 4)
        static let pointToPoint = Flags(rawValue: 8)
        static let multicast = Flags(rawValue: 16)
        static let running = Flags(rawValue: 32)
         
        static let available = Flags(rawValue: 256)
        static let isDefault = Flags(rawValue: 512)
        static let ownTunnel = Flags(rawValue: 1024)
    }

     
    struct RawInterface: Equatable {
        let name: String
        let index: UInt32
        let mtu: Int32
        let addresses: [String]
        let isUp: Bool
        let isRunning: Bool
        let isLoopback: Bool
        let isPointToPoint: Bool
        let isBroadcast: Bool
        let isMulticast: Bool
    }

     
    struct PathInterface: Equatable {
        let name: String
        let index: UInt32
        let type: Kind
    }

    struct Record: Equatable {
        let name: String
        let index: UInt32
        let mtu: Int32
        let addresses: [String]
        let flags: Flags
        let type: Kind
        let metered: Bool
    }

    static func build(
        raw: [RawInterface],
        available: [PathInterface],
        pathIsExpensive: Bool,
        defaultInterfaceIndex: UInt32,
        ownTunnelAddresses: Set<String>
    ) -> [Record] {
        raw.map { interface in
            let onPath = available.first { $0.index == interface.index && $0.name == interface.name }
            let isOwnTunnel = !ownTunnelAddresses.isEmpty
                && interface.addresses.contains { ownTunnelAddresses.contains($0) }
            let type: Kind
            if isOwnTunnel {
                type = .tunnel
            } else if let onPath {
                type = onPath.type
            } else {
                type = kindByName(interface)
            }
            var flags = Flags()
            if interface.isUp { flags.insert(.up) }
            if interface.isBroadcast { flags.insert(.broadcast) }
            if interface.isLoopback { flags.insert(.loopback) }
            if interface.isPointToPoint { flags.insert(.pointToPoint) }
            if interface.isMulticast { flags.insert(.multicast) }
            if interface.isRunning { flags.insert(.running) }
            if onPath != nil { flags.insert(.available) }
            if interface.index == defaultInterfaceIndex, defaultInterfaceIndex != 0 { flags.insert(.isDefault) }
            if isOwnTunnel { flags.insert(.ownTunnel) }
            return Record(
                name: interface.name,
                index: interface.index,
                mtu: interface.mtu,
                addresses: interface.addresses,
                flags: flags,
                type: type,
                metered: type == .cellular || (onPath != nil && pathIsExpensive)
            )
        }
    }

     
     
     
     
    static func enumerate() -> [RawInterface] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var order: [String] = []
        var folded: [String: RawInterface] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            var addresses: [String] = []
            if let address = interface.ifa_addr,
               Int32(address.pointee.sa_family) == AF_INET || Int32(address.pointee.sa_family) == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address, socklen_t(address.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    let literal = String(cString: host)
                    addresses.append(literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal)
                }
            }
            var mtu: Int32 = 0
            if let data = interface.ifa_data {
                mtu = Int32(clamping: data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
            }
            if let existing = folded[name] {
                folded[name] = RawInterface(
                    name: name,
                    index: existing.index != 0 ? existing.index : if_nametoindex(name),
                    mtu: existing.mtu != 0 ? existing.mtu : mtu,
                    addresses: existing.addresses + addresses,
                    isUp: existing.isUp, isRunning: existing.isRunning, isLoopback: existing.isLoopback,
                    isPointToPoint: existing.isPointToPoint, isBroadcast: existing.isBroadcast,
                    isMulticast: existing.isMulticast
                )
            } else {
                order.append(name)
                folded[name] = RawInterface(
                    name: name,
                    index: if_nametoindex(name),
                    mtu: mtu,
                    addresses: addresses,
                    isUp: flags & IFF_UP != 0,
                    isRunning: flags & IFF_RUNNING != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0,
                    isPointToPoint: flags & IFF_POINTOPOINT != 0,
                    isBroadcast: flags & IFF_BROADCAST != 0,
                    isMulticast: flags & IFF_MULTICAST != 0
                )
            }
        }
        return order.compactMap { folded[$0] }
    }

     
     
     
    private static func kindByName(_ interface: RawInterface) -> Kind {
        if interface.isLoopback || interface.name.hasPrefix("lo") { return .loopback }
        if interface.name.hasPrefix("pdp_ip") { return .cellular }
        if interface.name.hasPrefix("utun") || interface.name.hasPrefix("ipsec") { return .tunnel }
        if interface.name.hasPrefix("en") { return interface.isPointToPoint ? .other : .wifi }
        return .other
    }
}

 
enum PhysicalEgressBinding: Equatable {
    case bound(index: UInt32)
    case unscoped

    static func decision(interfaceIndex: UInt32) -> PhysicalEgressBinding {
        interfaceIndex == 0 ? .unscoped : .bound(index: interfaceIndex)
    }

    struct Failure: Error, CustomStringConvertible {
        let fd: Int32
        let errno: Int32
        var description: String { "IP_BOUND_IF failed for fd \(fd) (errno \(errno))" }
    }

     
     
     
    static func apply(_ decision: PhysicalEgressBinding, to fd: Int32) throws {
        guard case .bound(let index) = decision else { return }
        var value = index
        let v4 = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, socklen_t(MemoryLayout<UInt32>.size))
        let v6 = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &value, socklen_t(MemoryLayout<UInt32>.size))
        if v4 != 0, v6 != 0 {
            throw Failure(fd: fd, errno: Darwin.errno)
        }
    }
}

enum PhysicalPathStartupGateError: Error, Equatable {
    case timedOut
    case superseded
}

final class PhysicalPathStartupGate: @unchecked Sendable {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private enum State {
        case waiting
        case ready
        case superseded
    }

    private let lock = NSLock()
    private var currentGeneration: UInt64 = 0
    private var ready = false

    func begin() -> Generation {
        lock.lock()
        currentGeneration &+= 1
        ready = false
        let generation = Generation(value: currentGeneration)
        lock.unlock()
        return generation
    }

    @discardableResult
    func update(_ generation: Generation, isReady: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation.value == currentGeneration else { return false }
        ready = isReady
        return true
    }

    @discardableResult
    func invalidate(_ generation: Generation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation.value == currentGeneration else { return false }
        currentGeneration &+= 1
        ready = false
        return true
    }

    func wait(
        for generation: Generation,
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 50_000_000
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            switch state(for: generation) {
            case .ready:
                return
            case .superseded:
                throw PhysicalPathStartupGateError.superseded
            case .waiting:
                break
            }
            try await Task.sleep(nanoseconds: max(1, pollNanoseconds))
        }
        try Task.checkCancellation()
        switch state(for: generation) {
        case .ready:
            return
        case .superseded:
            throw PhysicalPathStartupGateError.superseded
        case .waiting:
            throw PhysicalPathStartupGateError.timedOut
        }
    }

    private func state(for generation: Generation) -> State {
        lock.lock(); defer { lock.unlock() }
        guard generation.value == currentGeneration else { return .superseded }
        return ready ? .ready : .waiting
    }
}

final class PhysicalPathMonitorSession: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = PhysicalPathStartupGate()
    private var monitor: (any PhysicalPathMonitoring)?
    private var generation: PhysicalPathStartupGate.Generation?

    func start(
        monitor newMonitor: any PhysicalPathMonitoring,
        queue: DispatchQueue,
        observer: @escaping (PhysicalPathSnapshot) -> Void
    ) -> PhysicalPathStartupGate.Generation {
        let previous = detachCurrent()
        previous?.updateHandler = nil
        previous?.cancel()

        let newGeneration = gate.begin()
        let monitorIdentifier = ObjectIdentifier(newMonitor)
        lock.lock()
        monitor = newMonitor
        generation = newGeneration
        lock.unlock()

        newMonitor.updateHandler = { [weak self] snapshot in
            guard let self,
                  self.isCurrent(monitorIdentifier, generation: newGeneration)
            else { return }
             
             
            observer(snapshot)
            _ = self.gate.update(newGeneration, isReady: snapshot.isReady)
        }
        newMonitor.start(queue: queue)
        return newGeneration
    }

    func wait(
        for generation: PhysicalPathStartupGate.Generation,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await gate.wait(for: generation, timeoutNanoseconds: timeoutNanoseconds)
    }

    func stop() {
        lock.lock()
        let currentMonitor = monitor
        let currentGeneration = generation
        monitor = nil
        generation = nil
        lock.unlock()
        currentMonitor?.updateHandler = nil
        currentMonitor?.cancel()
        if let currentGeneration {
            _ = gate.invalidate(currentGeneration)
        }
    }

    private func detachCurrent() -> (any PhysicalPathMonitoring)? {
        lock.lock()
        let currentMonitor = monitor
        let currentGeneration = generation
        monitor = nil
        generation = nil
        lock.unlock()
        if let currentGeneration {
            _ = gate.invalidate(currentGeneration)
        }
        return currentMonitor
    }

    private func isCurrent(
        _ identifier: ObjectIdentifier,
        generation candidate: PhysicalPathStartupGate.Generation
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let monitor, let generation else { return false }
        return ObjectIdentifier(monitor) == identifier && generation == candidate
    }
}


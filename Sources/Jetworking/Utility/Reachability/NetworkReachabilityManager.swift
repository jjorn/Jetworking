import Foundation
import SystemConfiguration

/// A implementation listens for reachability changes of hosts and addresses
/// for available network interfaces.
///
/// Network reachability cannot tell your application
/// if you can connect to a particular host,
/// only that an interface is available that might allow a connection,
/// and whether that interface is the WWAN.
open class NetworkReachabilityManager: NetworkReachabilityMonitor {
    public static let `default`: NetworkReachabilityManager? = try? NetworkReachabilityManager()

    // MARK: - Properties
    /// Determines whether the network is currently reachable.
    open var isReachable: Bool {
        state == .reachable(.cellular) || state == .reachable(.localWiFi)
    }

    /// Returns the current network reachability state.
    open var state: NetworkReachabilityState {
        flags.map(NetworkReachabilityState.init) ?? .notDetermined
    }

    /// `DispatchQueue` on which reachability will update.
    public let reachabilityQueue = DispatchQueue(label: "com.jamitlabs.jetworking.network-reachability")

    /// Flags of the current reachability type, if any.
    private var flags: SCNetworkReachabilityFlags? {
        var flags = SCNetworkReachabilityFlags()
        return (SCNetworkReachabilityGetFlags(reachability, &flags)) ? flags : nil
    }

    /// `SCNetworkReachability` instance providing notifications.
    private let reachability: SCNetworkReachability

    /// A runtime instance for state listener
    private var stateListener: NetworkReachabilityStateListener = .init()

    // MARK: - Initialization
    /// Creates an instance with the specified host.
    ///
    /// - Note: The `host` value must *not* contain a scheme (`http`, etc.), just the hostname.
    ///
    /// - Parameters:
    ///   - host: Host used to evaluate network reachability.
    public convenience init(host: String) throws {
        guard let reachability = SCNetworkReachabilityCreateWithName(nil, host) else {
            throw NSError(
                domain: kCFErrorDomainSystemConfiguration as String,
                code: Int(SCError()),
                userInfo: [NSLocalizedDescriptionKey: SCErrorString(SCError())]
            )
        }

        self.init(reachability: reachability)
    }

    /// Creates an instance that monitors the zero address (0.0.0.0).
    ///
    /// The reachability treats the address as a special token that causes it
    /// to actually monitor the general routing status of the device,
    /// both IPv4 and IPv6.
    public convenience init() throws {
        var zeroAddress = sockaddr()
        zeroAddress.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        zeroAddress.sa_family = sa_family_t(AF_INET)

        guard let reachability = SCNetworkReachabilityCreateWithAddress(nil, &zeroAddress) else {
            throw NSError(
                domain: kCFErrorDomainSystemConfiguration as String,
                code: Int(SCError()),
                userInfo: [NSLocalizedDescriptionKey: SCErrorString(SCError())]
            )
        }

        self.init(reachability: reachability)
    }

    init(reachability: SCNetworkReachability) {
        self.reachability = reachability
    }

    deinit {
        stopListening()
    }

    // MARK: - Listening
    /// Starts listening for changes in network reachability state.
    ///
    /// - Note: Stops and removes any existing listener.
    ///
    /// - Parameters:
    ///   - queue: A queue on which to call the callback closure. Use the main queue by default.
    ///   - callback: A closure called when reachability changes.
    open func startListening(
        on queue: DispatchQueue = .main,
        withCallbackOnStateChange callback: @escaping NetworkReachabilityStateCallback
    ) throws {
        stopListening()

        stateListener.update { state in
            state.callbackQueue = queue
            state.callback = callback
        }

        var context = SCNetworkReachabilityContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCNetworkReachabilityCallBack = { _, flags, info in
            guard let info = info else { return }

            let instance = Unmanaged<NetworkReachabilityManager>.fromOpaque(info).takeUnretainedValue()
            instance.notifyListener(flags)
        }

        if !SCNetworkReachabilitySetDispatchQueue(reachability, reachabilityQueue) {
            stopListening()
            throw NSError(
                domain: kCFErrorDomainSystemConfiguration as String,
                code: Int(SCError()),
                userInfo: [NSLocalizedDescriptionKey: SCErrorString(SCError())]
            )
        }

        if !SCNetworkReachabilitySetCallback(reachability, callback, &context) {
            stopListening()
            throw NSError(
                domain: kCFErrorDomainSystemConfiguration as String,
                code: Int(SCError()),
                userInfo: [NSLocalizedDescriptionKey: SCErrorString(SCError())]
            )
        }

        // Initial state check
        flags.flatMap { currentFlags in
            reachabilityQueue.async { self.notifyListener(currentFlags) }
        }
    }

    /// Stops listening for changes in network reachability state.
    open func stopListening() {
        SCNetworkReachabilitySetCallback(reachability, nil, nil)
        SCNetworkReachabilitySetDispatchQueue(reachability, nil)
        stateListener.reset()
    }

    // MARK: - Internal - Listener Notification
    /// Calls the callback closure in the callback queue if the computed state has been changed.
    ///
    /// - Note: Should only be called from the `reachabilityQueue`.
    ///
    /// - Parameter flags: `SCNetworkReachabilityFlags` to use to calculate the state.
    func notifyListener(_ flags: SCNetworkReachabilityFlags) {
        let newStatus = NetworkReachabilityState(flags)

        stateListener.update { listener in
            guard listener.previousStatus != newStatus else { return }

            listener.previousStatus = newStatus

            let callback = listener.callback
            listener.callbackQueue?.async { callback?(newStatus) }
        }
    }
}

import Foundation
import Network

class LPNetworkMonitor: ObservableObject {
    static let shared = LPNetworkMonitor()
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    @Published private(set) var isConnected: Bool = true
    private(set) var isInitialized: Bool = false
    
    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                self.isConnected = path.status == .satisfied
                
                if !self.isInitialized {
                    self.isInitialized = true
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() { monitor.cancel() }
    
    func checkConnection() -> Bool {
        // If we're not initialized yet, assume we're connected
        return !isInitialized || isConnected
    }
}

struct LPQueuedEvent: Codable {
    let type: String // Store LPApiType as String
    let data: [String: String] // Store only String values
    let timestamp: Date
    
    init(type: LPApiType, data: [String: Any], timestamp: Date) {
        self.type = type.rawValue
        self.data = data.compactMapValues { "\($0)" } // Convert all values to String
        self.timestamp = timestamp
    }
}

class LPEventQueue {
    private let queue = DispatchQueue(label: "com.lightpack.eventQueue")
    private let userDefaultsKey = "LPQueuedEvents"
    private var events: [LPQueuedEvent] = []
    
    init() { loadEvents() }
    
    func enqueue(event: LPQueuedEvent) {
        queue.async {
            self.events.append(event)
            self.saveEvents()
        }
    }
    
    func dequeueAll() -> [LPQueuedEvent] {
        var dequeuedEvents: [LPQueuedEvent] = []
        queue.sync {
            dequeuedEvents = self.events
            self.events.removeAll()
            self.saveEvents()
        }
        return dequeuedEvents
    }
    
    private func saveEvents() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(events) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
    
    private func loadEvents() {
        if let savedEvents = UserDefaults.standard.object(forKey: userDefaultsKey) as? Data {
            let decoder = JSONDecoder()
            if let loadedEvents = try? decoder.decode([LPQueuedEvent].self, from: savedEvents) {
                self.events = loadedEvents
            }
        }
    }
}

import Foundation

/// PA-04: retained-handle lookup by element hash. AX exposes no window
/// number, so identity is `CFEqual` on the retained element; a linear scan of
/// every handle under a lock ran for every moved/resized event. This index
/// buckets handles by the element's hash and verifies with the real equality
/// inside the (usually single-entry) bucket. Generic so the collision rules
/// are testable without Accessibility.
public struct HandleIndex<Element> {
    private struct Entry {
        let elementID: UInt64
        let pid: pid_t
        let element: Element
    }

    private let hash: (Element) -> Int
    private let equal: (Element, Element) -> Bool
    private var buckets: [Int: [Entry]] = [:]
    private var bucketOf: [UInt64: Int] = [:]

    public init(hash: @escaping (Element) -> Int, equal: @escaping (Element, Element) -> Bool) {
        self.hash = hash
        self.equal = equal
    }

    public var count: Int { bucketOf.count }

    /// Registering an ID again replaces its previous element.
    public mutating func insert(elementID: UInt64, pid: pid_t, element: Element) {
        remove(elementID: elementID)
        let key = hash(element)
        buckets[key, default: []].append(Entry(elementID: elementID, pid: pid, element: element))
        bucketOf[elementID] = key
    }

    public mutating func remove(elementID: UInt64) {
        guard let key = bucketOf.removeValue(forKey: elementID) else {
            return
        }
        buckets[key]?.removeAll { $0.elementID == elementID }
        if buckets[key]?.isEmpty == true {
            buckets.removeValue(forKey: key)
        }
    }

    public func find(_ element: Element, pid: pid_t) -> UInt64? {
        buckets[hash(element)]?.first { $0.pid == pid && equal($0.element, element) }?.elementID
    }
}

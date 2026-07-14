import Foundation

/// An ordered list of terminal surfaces ("tabs") for one worktree, plus the active
/// surface. Generic over `Handle` (the shell stores a `TerminalSurface`); pure so the
/// ordering/active rules are unit-testable with a stub handle.
public final class WorktreeSurfaces<Handle> {
    public struct Entry {
        public var surface: Surface
        public let handle: Handle
        public init(surface: Surface, handle: Handle) { self.surface = surface; self.handle = handle }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var activeSurfaceID: String?

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var handles: [Handle] { entries.map { $0.handle } }

    public func index(of id: String) -> Int? { entries.firstIndex { $0.surface.id == id } }
    public func entry(for id: String) -> Entry? { index(of: id).map { entries[$0] } }
    public func handle(for id: String) -> Handle? { entry(for: id)?.handle }

    public var activeEntry: Entry? { activeSurfaceID.flatMap { entry(for: $0) } }
    public var activeHandle: Handle? { activeEntry?.handle }
    public var activeSurface: Surface? { activeEntry?.surface }

    /// Insert a new surface after the active one (end if none) and make it active.
    public func add(_ handle: Handle, surface: Surface) {
        let insertAt = activeSurfaceID.flatMap { index(of: $0) }.map { $0 + 1 } ?? entries.count
        entries.insert(Entry(surface: surface, handle: handle), at: insertAt)
        activeSurfaceID = surface.id
    }

    /// Remove a surface, returning its handle. If it was active, select the right
    /// neighbor, else the left, else nil (worktree now empty).
    @discardableResult
    public func close(id: String) -> Handle? {
        guard let i = index(of: id) else { return nil }
        let removed = entries.remove(at: i)
        if activeSurfaceID == id {
            activeSurfaceID = entries.isEmpty ? nil : entries[min(i, entries.count - 1)].surface.id
        }
        return removed.handle
    }

    public func setActive(id: String) { if index(of: id) != nil { activeSurfaceID = id } }

    @discardableResult public func next() -> String? { advance(by: 1) }
    @discardableResult public func prev() -> String? { advance(by: -1) }

    private func advance(by step: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let cur = activeSurfaceID, let i = index(of: cur) else {
            activeSurfaceID = entries.first?.surface.id
            return activeSurfaceID
        }
        let n = entries.count
        activeSurfaceID = entries[((i + step) % n + n) % n].surface.id
        return activeSurfaceID
    }

    /// Activate the surface at a zero-based index; out-of-range is a no-op. Returns the active id.
    @discardableResult
    public func goTo(index: Int) -> String? {
        guard entries.indices.contains(index) else { return activeSurfaceID }
        activeSurfaceID = entries[index].surface.id
        return activeSurfaceID
    }

    public func rename(id: String, to name: String?) {
        guard let i = index(of: id) else { return }
        entries[i].surface.nameOverride = name
    }

    public func setColor(id: String, to color: IdentityColorValue?) {
        guard let i = index(of: id) else { return }
        entries[i].surface.colorOverride = color
    }
}

import SwiftUI
import AppKit

/// Collega doppio-click nativo e click sullo spazio vuoto di `NSTableView`
/// (deseleziona senza rubare il click singolo sulle righe a SwiftUI `Table`).
struct TableDoubleClickInstaller: NSViewRepresentable {
    var onDoubleClickRow: (Int) -> Void
    var onEmptyClick: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClickRow: onDoubleClickRow, onEmptyClick: onEmptyClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDoubleClickRow = onDoubleClickRow
        context.coordinator.onEmptyClick = onEmptyClick
        (nsView as? InstallerView)?.coordinator = context.coordinator
        (nsView as? InstallerView)?.installIfNeeded()
    }

    final class Coordinator: NSObject {
        var onDoubleClickRow: (Int) -> Void
        var onEmptyClick: (() -> Void)?
        fileprivate var mouseMonitor: Any?

        init(onDoubleClickRow: @escaping (Int) -> Void, onEmptyClick: (() -> Void)?) {
            self.onDoubleClickRow = onDoubleClickRow
            self.onEmptyClick = onEmptyClick
        }

        deinit {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
        }

        @objc func tableDoubleClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }
            let row = table.clickedRow
            guard row >= 0 else { return }
            onDoubleClickRow(row)
        }
    }

    final class InstallerView: NSView {
        weak var coordinator: Coordinator?
        private weak var installedTable: NSTableView?
        private var originalTarget: AnyObject?
        private var originalDoubleAction: Selector?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                self?.attach()
            }
        }

        private func attach() {
            guard let coordinator, let table = findTableView(from: self) else { return }
            if installedTable === table, table.doubleAction == #selector(Coordinator.tableDoubleClicked(_:)) {
                ensureEmptyClickMonitor(for: table, coordinator: coordinator)
                return
            }

            installedTable = table
            originalTarget = table.target as AnyObject?
            originalDoubleAction = table.doubleAction
            table.target = coordinator
            table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
            table.allowsEmptySelection = true
            ensureEmptyClickMonitor(for: table, coordinator: coordinator)
        }

        private func ensureEmptyClickMonitor(for table: NSTableView, coordinator: Coordinator) {
            if coordinator.mouseMonitor != nil { return }

            coordinator.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak table, weak coordinator] event in
                guard let table, let coordinator, let window = table.window, event.window === window else {
                    return event
                }

                let locationInTable = table.convert(event.locationInWindow, from: nil)
                // Solo area documento tabella (righe + spazio sotto l’ultima riga), non i bottoni fuori.
                let hitView = window.contentView?.hitTest(event.locationInWindow)
                let isInTableHierarchy = hitView.map { view in
                    var current: NSView? = view
                    while let node = current {
                        if node === table || node === table.enclosingScrollView { return true }
                        current = node.superview
                    }
                    return false
                } ?? false

                guard isInTableHierarchy else { return event }

                let row = table.row(at: locationInTable)
                if row < 0 {
                    DispatchQueue.main.async {
                        coordinator.onEmptyClick?()
                    }
                }
                return event
            }
        }

        private func findTableView(from view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if let table = node as? NSTableView { return table }
                for sub in node.subviews {
                    if let found = deepFind(sub) { return found }
                }
                current = node.superview
            }
            return nil
        }

        private func deepFind(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews {
                if let found = deepFind(sub) { return found }
            }
            if let scroll = view as? NSScrollView, let doc = scroll.documentView as? NSTableView {
                return doc
            }
            return nil
        }
    }
}

extension View {
    func onNativeTableDoubleClick(
        onEmptyClick: (() -> Void)? = nil,
        _ action: @escaping (Int) -> Void
    ) -> some View {
        background(
            TableDoubleClickInstaller(
                onDoubleClickRow: action,
                onEmptyClick: onEmptyClick
            )
        )
    }
}

import SwiftUI
import AppKit

/// Collega il doppio-click nativo di `NSTableView` senza rubare il click singolo a SwiftUI `Table`.
struct TableDoubleClickInstaller: NSViewRepresentable {
    var onDoubleClickRow: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClickRow: onDoubleClickRow)
    }

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDoubleClickRow = onDoubleClickRow
        (nsView as? InstallerView)?.coordinator = context.coordinator
        (nsView as? InstallerView)?.installIfNeeded()
    }

    final class Coordinator: NSObject {
        var onDoubleClickRow: (Int) -> Void

        init(onDoubleClickRow: @escaping (Int) -> Void) {
            self.onDoubleClickRow = onDoubleClickRow
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
                return
            }

            installedTable = table
            originalTarget = table.target as AnyObject?
            originalDoubleAction = table.doubleAction
            table.target = coordinator
            table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
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
            // Also search siblings up a bit from enclosing scroll view
            if let scroll = view as? NSScrollView, let doc = scroll.documentView as? NSTableView {
                return doc
            }
            return nil
        }
    }
}

extension View {
    func onNativeTableDoubleClick(_ action: @escaping (Int) -> Void) -> some View {
        background(TableDoubleClickInstaller(onDoubleClickRow: action))
    }
}

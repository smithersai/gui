import SwiftUI

struct RunTreeView: View {
    @ObservedObject var store: DevToolsStore
    @ObservedObject var lastLogStore: LastLogPerNodeStore
    var onInspectNode: ((Int) -> Void)? = nil

    var body: some View {
        LiveRunTreeView(
            store: store,
            lastLogStore: lastLogStore,
            onInspectNode: onInspectNode
        )
    }
}

import SwiftUI
import Combine

private struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var filetorWorkspace: AppModel? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

struct WorkspaceRoot: View {
    @StateObject private var workspace: WorkspaceOwner
    @Environment(\.openWindow) private var openWindow

    init(workspaceID: UUID) {
        _workspace = StateObject(wrappedValue: WorkspaceOwner(workspaceID: workspaceID))
    }

    var body: some View {
        let app = workspace.app
        ContentView(app: app)
            .focusedSceneValue(\.filetorWorkspace, app)
            .onAppear {
                app.openWindow = { url in
                    let id = UUID()
                    if let url { AppModel.windowLocations[id] = url }
                    openWindow(id: "workspace", value: id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                for group in app.groups where group.current.trashAccessDenied {
                    group.current.load()
                }
            }
            .onDisappear {
                app.stop()
            }
    }
}

/// StateObject defers construction until SwiftUI retains this window's owner.
/// An eager State initializer can create discarded models which consume the
/// first-window restoration and overwrite the most recent workspace.
private final class WorkspaceOwner: ObservableObject {
    let app: AppModel
    init(workspaceID: UUID) { app = AppModel(workspaceID: workspaceID) }
}

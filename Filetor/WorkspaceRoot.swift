import SwiftUI

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
    @State private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    init(workspaceID: UUID) {
        _app = State(initialValue: AppModel(workspaceID: workspaceID))
    }

    var body: some View {
        ContentView(app: app)
            .focusedSceneValue(\.filetorWorkspace, app)
            .onAppear {
                app.openWindow = { url in
                    let id = UUID()
                    if let url { AppModel.windowLocations[id] = url }
                    openWindow(id: "workspace", value: id)
                }
            }
            .onDisappear {
                app.stop()
            }
    }
}

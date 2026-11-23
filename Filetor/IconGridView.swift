import SwiftUI

/// Icon view: grid of large icons with names under them.
struct IconGridView: View {
    let pane: PaneModel
    let app: AppModel
    let scale: CGFloat
    @FocusState private var fileListFocused: Bool
    @AppStorage("gridIconSize") private var gridIconSize = 52.0
    @AppStorage("showExtensions") private var showExtensions = true
    @AppStorage("iconPreviews") private var previews = false
    @AppStorage("foldersFirst") private var foldersFirst = true
    private var iconSide: CGFloat { CGFloat(min(max(gridIconSize, 32), 128)) * scale }

    var body: some View {
        let _ = foldersFirst
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: max(96 * scale, iconSide + 32)), spacing: 6)], spacing: 10) {
                ForEach(pane.sortedItems) { item in
                    let selected = pane.selection.contains(item.url)
                    VStack(spacing: 4) {
                        FileIcon(item: item, side: iconSide, previews: previews)
                            .frame(width: iconSide, height: iconSide)
                        Text(item.displayName(showExtension: showExtensions))
                            .font(.system(size: 12 * scale))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.filetor : Color.clear))
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.primary.opacity(0.08) : Color.clear))
                    .contentShape(Rectangle())
                    .draggable(item.url)
                    .contextMenu { FileItemMenu(item: item, pane: pane, app: app) }
                    .onTapGesture(count: 2) { pane.open([item.url]) }
                    .onTapGesture {
                        fileListFocused = true
                        app.activate(pane)
                        if NSEvent.modifierFlags.contains(.command) {
                            if selected { pane.selection.remove(item.url) } else { pane.selection.insert(item.url) }
                        } else {
                            pane.selection = [item.url]
                        }
                    }
                }
            }
            .padding(12)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($fileListFocused)
        .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty,
                  !pane.selection.isEmpty else { return .ignored }
            app.activate(pane)
            app.quickLook(pane.selection, toggle: true)
            return .handled
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu { FolderBackgroundMenu(pane: pane, app: app, directory: pane.currentURL) }
        .onTapGesture { pane.selection = [] }
    }
}

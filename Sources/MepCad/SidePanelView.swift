import SwiftUI
import MepCore
import MepTools

// MARK: - ガラス調自動格納サイドパネル(M4)
//
// モックv0.4の「Dock風パネル」の実体化。カーソルが右端に近づくと現れ、
// 離れると自動で格納される。ピンで常時表示にもできる。
// 収容: レイヤパネル + プロパティパネル(仕上げのアニメ調整はM5)。

struct SidePanelView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダ(ピン)
            HStack {
                Text("パネル")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    uiState.panelPinned.toggle()
                } label: {
                    Image(systemName: uiState.panelPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(uiState.panelPinned ? "自動格納に戻す" : "常時表示にピン留め")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 8)

            // レイヤ
            LayerListView(controller: controller, uiState: uiState)

            Divider().padding(.horizontal, 8)

            // プロパティ(オブジェクト属性用にスペースを確保)
            PropertyPanelView(controller: controller, uiState: uiState)

            Spacer(minLength: 8)
        }
        .frame(width: 248)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: -2, y: 4)
        .padding(.vertical, 12)
        .padding(.trailing, 10)
    }
}

// MARK: - レイヤパネル

struct LayerListView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("レイヤ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(uiState.layers) { layer in
                        LayerRowView(layer: layer,
                                     isCurrent: layer.id == uiState.currentLayerID,
                                     colorProvider: { uiState.paletteColor($0) },
                                     onToggleVisible: { controller.setLayerVisible(layer.id, !layer.isVisible) },
                                     onToggleLock: { controller.setLayerLocked(layer.id, layer.isEditable) },
                                     onSetCurrent: { controller.setCurrentLayer(layer.id) })
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 236)
            .padding(.bottom, 6)
        }
    }
}

struct LayerRowView: View {
    let layer: Layer
    let isCurrent: Bool
    let colorProvider: (Int) -> Color
    let onToggleVisible: () -> Void
    let onToggleLock: () -> Void
    let onSetCurrent: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // 表示/非表示
            Button(action: onToggleVisible) {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("表示/非表示")

            // ロック
            Button(action: onToggleLock) {
                Image(systemName: layer.isEditable ? "lock.open" : "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isEditable ? Color.secondary : Color.orange)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("ロック(選択・編集の対象外にする)")

            // 既定色
            Circle()
                .fill(colorProvider(layer.defaultColorIndex))
                .frame(width: 8, height: 8)

            // 名前(クリックでカレントに)
            Text(layer.name)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(layer.isVisible ? .primary : .secondary)

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .help("カレントレイヤ(作図先)")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.blue.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSetCurrent)
    }
}

// MARK: - プロパティパネル

struct PropertyPanelView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    private let lineTypes: [(Int?, String)] = [
        (nil, "レイヤ既定"), (0, "実線"), (1, "破線"), (2, "一点鎖線"),
    ]
    private let lineWeights: [(Double?, String)] = [
        (nil, "レイヤ既定"), (0.1, "0.1"), (0.15, "0.15"), (0.25, "0.25"),
        (0.35, "0.35"), (0.5, "0.5"), (0.7, "0.7"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("プロパティ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            if let sel = uiState.selection {
                Text(summaryText(sel))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)

                propertyRow("色") {
                    Menu {
                        Button("レイヤ既定") { controller.applyColorIndex(nil) }
                        ForEach(0..<10, id: \.self) { i in
                            Button {
                                controller.applyColorIndex(i)
                            } label: {
                                Label("色 \(i)", systemImage: "circle.fill")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if case let idx?? = sel.commonColorIndex {
                                Circle().fill(uiState.paletteColor(idx)).frame(width: 9, height: 9)
                                Text("色 \(idx)")
                            } else if sel.commonColorIndex != nil {
                                Text("レイヤ既定")
                            } else {
                                Text("混在")
                            }
                        }
                        .font(.system(size: 11))
                    }
                }

                propertyRow("線種") {
                    Menu {
                        ForEach(lineTypes.indices, id: \.self) { i in
                            Button(lineTypes[i].1) { controller.applyLineType(lineTypes[i].0) }
                        }
                    } label: {
                        Text(lineTypeLabel(sel)).font(.system(size: 11))
                    }
                }

                propertyRow("太さ") {
                    Menu {
                        ForEach(lineWeights.indices, id: \.self) { i in
                            Button(lineWeights[i].1) { controller.applyLineWeight(lineWeights[i].0) }
                        }
                    } label: {
                        Text(lineWeightLabel(sel)).font(.system(size: 11))
                    }
                }

                propertyRow("レイヤ") {
                    Menu {
                        ForEach(uiState.layers.filter { $0.isEditable && !$0.isUnderlay }) { layer in
                            Button(layer.name) { controller.moveSelectionToLayer(layer.id) }
                        }
                    } label: {
                        Text(layerLabel(sel)).font(.system(size: 11))
                            .lineLimit(1)
                    }
                }

                // クイック操作(右クリックと同じ)
                HStack(spacing: 6) {
                    Button("複写") { controller.beginEditOperation(.copy) }
                    Button("移動") { controller.beginEditOperation(.move) }
                    Button(role: .destructive) {
                        controller.deleteSelection()
                    } label: {
                        Text("削除")
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            } else {
                Text("選択なし")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("クリック=選択\n左→右ドラッグ=窓選択\n右→左ドラッグ=交差選択")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func propertyRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func summaryText(_ sel: SelectionSummary) -> String {
        var parts: [String] = []
        if sel.lineCount > 0 { parts.append("線\(sel.lineCount)") }
        if sel.circleCount > 0 { parts.append("円\(sel.circleCount)") }
        if sel.arcCount > 0 { parts.append("弧\(sel.arcCount)") }
        if sel.textCount > 0 { parts.append("字\(sel.textCount)") }
        return "\(sel.count)個選択中(\(parts.joined(separator: " ")))"
    }

    private func lineTypeLabel(_ sel: SelectionSummary) -> String {
        guard let common = sel.commonLineType else { return "混在" }
        guard let type = common else { return "レイヤ既定" }
        switch type {
        case 0: return "実線"
        case 1: return "破線"
        case 2: return "一点鎖線"
        default: return "線種\(type)"
        }
    }

    private func lineWeightLabel(_ sel: SelectionSummary) -> String {
        guard let common = sel.commonLineWeight else { return "混在" }
        guard let weight = common else { return "レイヤ既定" }
        return String(format: "%.2fmm", weight)
    }

    private func layerLabel(_ sel: SelectionSummary) -> String {
        guard let layerID = sel.commonLayerID else { return "混在" }
        return uiState.layers.first(where: { $0.id == layerID })?.name ?? "—"
    }
}

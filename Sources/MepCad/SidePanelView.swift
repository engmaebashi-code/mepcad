import SwiftUI
import MepCore
import MepTools

// MARK: - ガラス調自動格納サイドパネル(M4.1)
//
// カーソルが右端に近づくと現れ、離れると自動で格納される(ピンで常時表示)。
// レイヤは専用カード(グループ4×4+レイヤ一覧)、プロパティは別カードに分離。

struct SidePanelView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            // ピン(共通ヘッダ)
            HStack {
                Spacer()
                Button {
                    uiState.panelPinned.toggle()
                } label: {
                    Image(systemName: uiState.panelPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(uiState.panelPinned ? "自動格納に戻す" : "常時表示にピン留め")
            }
            .padding(.horizontal, 4)

            // レイヤ専用カード
            LayerPanelView(controller: controller, uiState: uiState)
                .glassCard()

            // プロパティ専用カード
            PropertyPanelView(controller: controller, uiState: uiState)
                .glassCard()

            Spacer(minLength: 0)
        }
        .frame(width: 272)
        .padding(.vertical, 12)
        .padding(.trailing, 10)
    }
}

private extension View {
    /// ガラス調カード(半透明マテリアル+角丸+枠+影)
    func glassCard() -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 12, x: -2, y: 3)
    }
}

// MARK: - レイヤ専用パネル(グループ4×4グリッド+レイヤ一覧)

struct LayerPanelView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    private var viewingGroup: LayerGroup {
        uiState.groups.indices.contains(uiState.viewingGroup)
            ? uiState.groups[uiState.viewingGroup]
            : LayerGroup()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("レイヤ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // 表示中グループの縮尺
                Text("グループ\(String(format: "%X", uiState.viewingGroup))  \(viewingGroup.scaleLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // グループ 4×4 グリッド(Jw_cad のグループバー相当)
            // クリック=そのグループのレイヤを下に表示 / 右クリック=表示・ロック・書込先
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { col in
                            let g = row * 4 + col
                            GroupCellView(index: g,
                                          group: uiState.groups.indices.contains(g) ? uiState.groups[g] : LayerGroup(),
                                          isViewing: g == uiState.viewingGroup,
                                          isCurrent: g == uiState.current.group,
                                          isEmpty: uiState.groupCount(g) == 0,
                                          onSelect: { uiState.viewingGroup = g },
                                          onToggleVisible: { v in controller.setGroupVisible(g, v) },
                                          onToggleLock: { locked in controller.setGroupLocked(g, locked) })
                        }
                    }
                }
            }
            .padding(.horizontal, 12)

            Divider().padding(.horizontal, 8)

            // 表示中グループの16レイヤ
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(0..<16, id: \.self) { l in
                        let address = LayerAddress(uiState.viewingGroup, l)
                        LayerRowView(index: l,
                                     layer: viewingGroup.layers.indices.contains(l) ? viewingGroup.layers[l] : Layer(),
                                     isCurrent: address == uiState.current,
                                     groupDimmed: !viewingGroup.isVisible,
                                     entityCount: uiState.count(at: address),
                                     colorProvider: { uiState.paletteColor($0) },
                                     onToggleVisible: { v in controller.setLayerVisible(address, v) },
                                     onToggleLock: { locked in controller.setLayerLocked(address, locked) },
                                     onSetCurrent: { controller.setCurrentLayer(address) })
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 300)
            .padding(.bottom, 8)
        }
    }
}

/// グループグリッドの1セル
struct GroupCellView: View {
    let index: Int
    let group: LayerGroup
    let isViewing: Bool
    let isCurrent: Bool
    /// 要素が1つも無いグループ(数字を薄くする)
    let isEmpty: Bool
    let onSelect: () -> Void
    let onToggleVisible: (Bool) -> Void
    let onToggleLock: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(format: "%X", index))
                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(cellForeground)
                    .frame(maxWidth: .infinity, minHeight: 26)
                if !group.isEditable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .padding(2)
                }
            }
            .background(cellBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isViewing ? Color.blue : Color.primary.opacity(0.12),
                                  lineWidth: isViewing ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("グループ\(String(format: "%X", index)) (\(group.scaleLabel)) — クリックでレイヤ一覧を表示 / 右クリックで表示・ロック")
        .contextMenu {
            Button(group.isVisible ? "グループを非表示" : "グループを表示") {
                onToggleVisible(!group.isVisible)
            }
            Button(group.isEditable ? "グループをロック" : "ロックを解除") {
                onToggleLock(group.isEditable)
            }
        }
    }

    private var cellForeground: Color {
        if isCurrent { return .white }
        if !group.isVisible { return Color.primary.opacity(0.25) }
        // 空グループは薄く(中身のあるグループがひと目で分かる)
        return isEmpty ? Color.primary.opacity(0.3) : .primary
    }

    private var cellBackground: Color {
        if isCurrent { return .blue }
        if !group.isVisible { return Color.primary.opacity(0.04) }
        return Color.primary.opacity(0.07)
    }
}

/// レイヤ一覧の1行(ボタンは大きめのクリック領域を確保)
struct LayerRowView: View {
    let index: Int
    let layer: Layer
    let isCurrent: Bool
    let groupDimmed: Bool
    /// このレイヤ上の要素数(0=空レイヤは行ごと薄く表示)
    let entityCount: Int
    let colorProvider: (Int) -> Color
    let onToggleVisible: (Bool) -> Void
    let onToggleLock: (Bool) -> Void
    let onSetCurrent: () -> Void

    private var isEmpty: Bool { entityCount == 0 }

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%X", index))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            // 表示/非表示(クリック領域 26×24)
            Button {
                onToggleVisible(!layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("表示/非表示")

            // ロック(クリック領域 26×24)
            Button {
                onToggleLock(layer.isEditable)
            } label: {
                Image(systemName: layer.isEditable ? "lock.open" : "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(layer.isEditable ? Color.secondary : Color.orange)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ロック(選択・編集の対象外にする)")

            Circle()
                .fill(colorProvider(layer.defaultColorIndex))
                .frame(width: 8, height: 8)

            Text(layer.name.isEmpty ? "レイヤ\(String(format: "%X", index))" : layer.name)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(rowTextStyle)

            Spacer(minLength: 0)

            // 要素数(空レイヤは表示しない)
            if entityCount > 0 {
                Text("\(entityCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if isCurrent {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                    .help("書込レイヤ(作図先)")
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(isCurrent ? Color.blue.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        // 空レイヤは行ごと薄く(中身のあるレイヤがひと目で分かる)
        .opacity(isEmpty && !isCurrent ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSetCurrent)
        .help("クリックで書込レイヤにする")
    }

    private var rowTextStyle: Color {
        if groupDimmed || !layer.isVisible { return Color.primary.opacity(0.35) }
        return layer.name.isEmpty ? Color.primary.opacity(0.6) : .primary
    }
}

// MARK: - プロパティ専用パネル

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
                .padding(.top, 10)

            if let sel = uiState.selection {
                Text(summaryText(sel))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)

                propertyRow("色") {
                    Menu {
                        Button("レイヤ既定") { controller.applyColorIndex(nil) }
                        ForEach(0..<10, id: \.self) { i in
                            Button("色 \(i)") { controller.applyColorIndex(i) }
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
                    Text(layerLabel(sel))
                        .font(.system(size: 11))
                        .lineLimit(1)
                }

                // レイヤ間の移動・複写(グループ→レイヤの2段メニュー)
                HStack(spacing: 6) {
                    layerPickerMenu("レイヤへ移動") { controller.moveSelectionToLayer($0) }
                    layerPickerMenu("レイヤへ複写") { controller.copySelectionToLayer($0) }
                }
                .padding(.top, 2)

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
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// グループ→レイヤの2段選択メニュー
    private func layerPickerMenu(_ title: String, action: @escaping (LayerAddress) -> Void) -> some View {
        Menu(title) {
            ForEach(0..<16, id: \.self) { g in
                let group = uiState.groups.indices.contains(g) ? uiState.groups[g] : LayerGroup()
                Menu(groupMenuTitle(g, group)) {
                    ForEach(0..<16, id: \.self) { l in
                        let address = LayerAddress(g, l)
                        Button(layerMenuTitle(address, group)) { action(address) }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func groupMenuTitle(_ g: Int, _ group: LayerGroup) -> String {
        let name = group.name.isEmpty ? "グループ\(String(format: "%X", g))" : group.name
        return "\(name) (\(group.scaleLabel))"
    }

    private func layerMenuTitle(_ address: LayerAddress, _ group: LayerGroup) -> String {
        let layer = group.layers.indices.contains(address.layer) ? group.layers[address.layer] : Layer()
        return layer.name.isEmpty ? address.description : "\(address.description) \(layer.name)"
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
        guard let address = sel.commonLayer else { return "混在" }
        return controller.layerDisplayName(address)
    }
}

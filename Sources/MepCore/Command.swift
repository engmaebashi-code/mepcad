import Foundation

/// Undo可能な編集操作。doitと逆操作undoを必ず対で実装する。
public protocol Command {
    var name: String { get }
    func execute(on document: Document)
    func undo(on document: Document)
}

public struct AddEntityCommand: Command {
    public let name = "追加"
    private let entity: Entity

    public init(entity: Entity) {
        self.entity = entity
    }

    public func execute(on document: Document) {
        document.add(entity)
    }

    public func undo(on document: Document) {
        _ = document.remove(id: entity.id)
    }
}

public struct RemoveEntityCommand: Command {
    public let name = "削除"
    private let entity: Entity

    /// entityは削除前のスナップショットを渡す
    public init(entity: Entity) {
        self.entity = entity
    }

    public func execute(on document: Document) {
        _ = document.remove(id: entity.id)
    }

    public func undo(on document: Document) {
        document.add(entity)
    }
}

/// 複数エンティティの一括追加(複写の確定などに使用)
public struct AddEntitiesCommand: Command {
    public let name: String
    private let entities: [Entity]

    public init(name: String = "追加", entities: [Entity]) {
        self.name = name
        self.entities = entities
    }

    public func execute(on document: Document) {
        document.appendBulk(entities)
    }

    public func undo(on document: Document) {
        document.removeBulk(ids: Set(entities.map(\.id)))
    }
}

/// 複数エンティティの一括削除。
/// Undoでは元の配列位置に戻し、重なり順(描画順・選択優先順)まで復元する。
public final class RemoveEntitiesCommand: Command {
    public let name = "削除"
    private let ids: Set<EntityID>
    private var removed: [(index: Int, entity: Entity)] = []

    /// entitiesは削除前のスナップショットを渡す(idのみ使用)
    public init(entities: [Entity]) {
        self.ids = Set(entities.map(\.id))
    }

    public init(ids: Set<EntityID>) {
        self.ids = ids
    }

    public func execute(on document: Document) {
        removed = document.removeBulkIndexed(ids: ids)
    }

    public func undo(on document: Document) {
        document.insertBulk(removed)
    }
}

/// 複数エンティティの平行移動(移動コマンド)。
/// Undoは逆方向移動ではなくスナップショット復元(浮動小数の往復誤差を残さない)。
public final class TranslateEntitiesCommand: Command {
    public let name = "移動"
    private let ids: Set<EntityID>
    private let delta: Vec2
    private var before: [Entity] = []

    public init(ids: Set<EntityID>, delta: Vec2) {
        self.ids = ids
        self.delta = delta
    }

    public func execute(on document: Document) {
        before = document.entities(ids: ids)
        document.translateBulk(ids: ids, by: delta)
    }

    public func undo(on document: Document) {
        document.replaceBulk(before)
    }
}

/// 移動+接続追随(M7.3)。動かした配管に取り付いている配管の端も同時に更新し、
/// 1回のUndoで両方が元に戻るようにする
public final class TranslateWithFollowersCommand: Command {
    public let name = "移動"
    private let ids: Set<EntityID>
    private let delta: Vec2
    /// 追随して姿が変わる配管(更新後の姿)
    private let followers: [Entity]
    private var before: [Entity] = []

    public init(ids: Set<EntityID>, delta: Vec2, followers: [Entity]) {
        self.ids = ids
        self.delta = delta
        self.followers = followers
    }

    public func execute(on document: Document) {
        before = document.entities(ids: ids)
            + document.entities(ids: Set(followers.map(\.id)))
        document.translateBulk(ids: ids, by: delta)
        document.replaceBulk(followers)
    }

    public func undo(on document: Document) {
        document.replaceBulk(before)
    }
}

/// 複数エンティティの回転(回転コマンド)。
/// Undoはスナップショット復元(三角関数の往復誤差を残さない)。
public final class RotateEntitiesCommand: Command {
    public let name = "回転"
    private let ids: Set<EntityID>
    private let center: Vec2
    private let angle: Double   // rad, CCW
    private var before: [Entity] = []

    public init(ids: Set<EntityID>, center: Vec2, angle: Double) {
        self.ids = ids
        self.center = center
        self.angle = angle
    }

    public func execute(on document: Document) {
        before = document.entities(ids: ids)
        document.replaceBulk(before.map { $0.rotated(around: center, byRadians: angle) })
    }

    public func undo(on document: Document) {
        document.replaceBulk(before)
    }
}

/// 複数エンティティへの任意変換(回転しながら移動・鏡映など)。
/// Undoはスナップショット復元。
public final class TransformEntitiesCommand: Command {
    public let name: String
    private let ids: Set<EntityID>
    private let transform: (Entity) -> Entity
    private var before: [Entity] = []

    public init(name: String, ids: Set<EntityID>, transform: @escaping (Entity) -> Entity) {
        self.name = name
        self.ids = ids
        self.transform = transform
    }

    public func execute(on document: Document) {
        before = document.entities(ids: ids)
        document.replaceBulk(before.map(transform))
    }

    public func undo(on document: Document) {
        document.replaceBulk(before)
    }
}

/// 複数エンティティの属性変更(プロパティパネルからの一括変更)
public struct UpdateEntitiesCommand: Command {
    public let name: String
    private let before: [Entity]
    private let after: [Entity]

    /// beforeとafterは同じidの集合であること
    public init(name: String = "属性変更", before: [Entity], after: [Entity]) {
        self.name = name
        self.before = before
        self.after = after
    }

    public func execute(on document: Document) {
        document.replaceBulk(after)
    }

    public func undo(on document: Document) {
        document.replaceBulk(before)
    }
}

/// 複数コマンドを1回のUndoにまとめる(ストレッチ等の複合操作用)
public struct CommandGroup: Command {
    public let name: String
    private let commands: [Command]

    public init(name: String, commands: [Command]) {
        self.name = name
        self.commands = commands
    }

    public func execute(on document: Document) {
        for c in commands { c.execute(on: document) }
    }

    public func undo(on document: Document) {
        for c in commands.reversed() { c.undo(on: document) }
    }
}

public final class CommandStack {
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []
    private unowned let document: Document

    public init(document: Document) {
        self.document = document
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 履歴を全消去する(新規作成・ファイルを開いた時。前の図面への取り消しを残さない)
    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public func run(_ command: Command) {
        command.execute(on: document)
        undoStack.append(command)
        redoStack.removeAll()
    }

    public func undo() {
        guard let c = undoStack.popLast() else { return }
        c.undo(on: document)
        redoStack.append(c)
    }

    public func redo() {
        guard let c = redoStack.popLast() else { return }
        c.execute(on: document)
        undoStack.append(c)
    }
}

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

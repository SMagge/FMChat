import SwiftUI
import FoundationModels

@main
struct FMChatApp: App {
    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Apple On-Device Chat") {
            ChatView()
                .frame(minWidth: 480, minHeight: 520)
        }
    }
}

struct Message: Identifiable {
    enum Role { case user, assistant, tool }
    let id: UUID
    let role: Role
    var text: String

    init(role: Role, text: String, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Tool activity relay (lets tools post notes into the chat)

final class ActivityRelay: @unchecked Sendable {
    var handler: (@Sendable (String) -> Void)?
    func post(_ note: String) { handler?(note) }
}

// MARK: - Tools (read-only access to local files)

private func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

private func clip(_ text: String, limit: Int = 4000) -> String {
    text.count > limit
        ? String(text.prefix(limit)) + "\n…[truncated \(text.count - limit) characters]"
        : text
}

struct ListDirectoryTool: Tool {
    let name = "listDirectory"
    let description = "List the files and folders inside a directory on this Mac. Folders end with '/'."
    let relay: ActivityRelay

    var parameters: GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                GenerationSchema.Property(
                    name: "path",
                    description: "Absolute or ~/ path of the directory to list",
                    type: String.self
                )
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let path = expandPath(try arguments.value(String.self, forProperty: "path"))
        relay.post("📁 listDirectory \(path)")
        do {
            let fm = FileManager.default
            let entries = try fm.contentsOfDirectory(atPath: path).sorted()
            let lines = entries.prefix(100).map { entry -> String in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path + "/" + entry, isDirectory: &isDir)
                return isDir.boolValue ? entry + "/" : entry
            }
            return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

struct ReadFileTool: Tool {
    let name = "readFile"
    let description = "Read the contents of a text file at a path on this Mac."
    let relay: ActivityRelay

    var parameters: GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                GenerationSchema.Property(
                    name: "path",
                    description: "Absolute or ~/ path of the file to read",
                    type: String.self
                )
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let path = expandPath(try arguments.value(String.self, forProperty: "path"))
        relay.post("📄 readFile \(path)")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Error: could not read \(path) as UTF-8 text."
        }
        return clip(text)
    }
}

struct SearchTextTool: Tool {
    let name = "searchText"
    let description = "Recursively search for a text string in files under a directory. Returns matching lines prefixed with file path and line number."
    let relay: ActivityRelay

    var parameters: GenerationSchema {
        GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                GenerationSchema.Property(
                    name: "query",
                    description: "Exact text to search for",
                    type: String.self
                ),
                GenerationSchema.Property(
                    name: "path",
                    description: "Absolute or ~/ path of the directory to search in",
                    type: String.self
                ),
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let query = try arguments.value(String.self, forProperty: "query")
        let path = expandPath(try arguments.value(String.self, forProperty: "path"))
        relay.post("🔍 searchText \"\(query)\" in \(path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [
            "-rnIF", "-m", "3",
            "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=target",
            query, path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.isEmpty ? "No matches found." : clip(output)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Chat model

@MainActor
@Observable
final class ChatModel {
    var messages: [Message] = []
    var isResponding = false
    var availabilityNote: String?

    private var session: LanguageModelSession
    private let relay = ActivityRelay()
    private var pendingReplyID: UUID?

    private static func makeSession(relay: ActivityRelay) -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                ListDirectoryTool(relay: relay),
                ReadFileTool(relay: relay),
                SearchTextTool(relay: relay),
            ],
            instructions: """
            You are a helpful, concise assistant running fully on-device on this Mac.
            You can inspect the user's local files with the listDirectory, readFile, and \
            searchText tools. Use them whenever the user asks about their files, folders, \
            or code, then answer based on what you found. When calling a tool, pass the \
            path exactly as the user wrote it, character for character, including ~. \
            Never invent or alter paths. Keep answers short.
            """
        )
    }

    init() {
        session = Self.makeSession(relay: relay)
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            availabilityNote = "Model unavailable: \(reason)"
        }
        relay.handler = { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                if let pending = self.pendingReplyID,
                   let index = self.messages.firstIndex(where: { $0.id == pending }) {
                    self.messages.insert(Message(role: .tool, text: note), at: index)
                } else {
                    self.messages.append(Message(role: .tool, text: note))
                }
            }
        }
    }

    func send(_ text: String) async {
        messages.append(Message(role: .user, text: text))
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        pendingReplyID = reply.id
        isResponding = true
        defer {
            isResponding = false
            pendingReplyID = nil
        }
        do {
            let stream = session.streamResponse(to: text)
            for try await snapshot in stream {
                if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                    messages[index].text = snapshot.content
                }
            }
        } catch {
            if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                messages[index].text = "⚠️ \(error.localizedDescription)"
            }
        }
    }

    func reset() {
        session = Self.makeSession(relay: relay)
        messages.removeAll()
    }
}

// MARK: - Views

struct ChatView: View {
    @State private var model = ChatModel()
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let note = model.availabilityNote {
                Text(note)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.messages) { message in
                            BubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask about anything, including your files…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(sendCurrent)
                if model.isResponding {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: sendCurrent) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .toolbar {
            Button("New Chat", systemImage: "square.and.pencil") {
                model.reset()
            }
            .disabled(model.isResponding)
        }
        .onAppear { focused = true }
    }

    private func sendCurrent() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isResponding else { return }
        input = ""
        Task { await model.send(text) }
    }
}

struct BubbleView: View {
    let message: Message

    var body: some View {
        if message.role == .tool {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }
                Group {
                    if message.text.isEmpty {
                        ProgressView().controlSize(.small).padding(6)
                    } else {
                        Text(LocalizedStringKey(message.text))
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(message.role == .user ? .white : .primary)
                if message.role == .assistant { Spacer(minLength: 60) }
            }
        }
    }
}

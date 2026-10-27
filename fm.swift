import Foundation
import FoundationModels

// fm — chat with Apple's on-device Foundation Model from the terminal.
// Usage:
//   fm <prompt>                      one-shot prompt from arguments
//   echo "prompt" | fm               prompt from stdin
//   cat notes.txt | fm "summarize"   arguments + piped input combined

var parts: [String] = []
let args = CommandLine.arguments.dropFirst()
if !args.isEmpty {
    parts.append(args.joined(separator: " "))
}
if isatty(0) == 0 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let piped = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !piped.isEmpty {
        parts.append(piped)
    }
}
let prompt = parts.joined(separator: "\n\n")

guard !prompt.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: fm <prompt>
           echo "prompt" | fm
           cat file.txt | fm "summarize this"

    """.utf8))
    exit(64)
}

if case .unavailable(let reason) = SystemLanguageModel.default.availability {
    FileHandle.standardError.write(Data("fm: model unavailable: \(reason)\n".utf8))
    exit(1)
}

let session = LanguageModelSession()
do {
    var printed = 0
    for try await snapshot in session.streamResponse(to: prompt) {
        let content = snapshot.content
        if content.count > printed {
            print(String(content.dropFirst(printed)), terminator: "")
            fflush(stdout)
            printed = content.count
        }
    }
    print()
} catch {
    FileHandle.standardError.write(Data("fm: \(error.localizedDescription)\n".utf8))
    exit(1)
}

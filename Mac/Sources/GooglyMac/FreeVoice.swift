import Foundation
import GooglyShared

// FreeVoice: OPTIONAL voice that doesn't need OpenAI. It is only used while "Free AI" is turned on
// in Bluey's menu. The iPhone turns your speech into text and sends just the text here; the free AI
// works out what you meant, and Bluey's usual commands do the rest. He answers in his bubble.
//
// TO REMOVE: delete this file and the lines marked `// FreeVoice` in other files (or discard the branch).
@MainActor
enum FreeVoice {
    /// The last few turns, so follow-ups make sense. Lives in memory only.
    private static var history: [[String: Any]] = []

    /// `runTool` runs one of Bluey's own tools (handed in by RealtimeHost, which owns them).
    static func handle(_ packet: Packet, context: String?,
                       runTool: @escaping (String, String) async -> String,
                       reply: @escaping (Packet) -> Void) {
        let words = String((packet.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        let callID = packet.callID
        Task { @MainActor in
            let result = await respond(to: words, context: context, runTool: runTool)
            reply(Packet(command: "voiceReply", callID: callID, tool: result.sleep ? "go_to_sleep" : nil, text: result.text))
        }
    }

    // MARK: What the free AI is told

    private static let guide = """
    You are the voice of Bluey, a little blueberry who helps the user focus and does small jobs on their Mac.
    The user just spoke to you. Decide what they want, then answer with ONLY one JSON object and nothing else, like this:
    {"action":"none","reply":"...","task":"","minutes":30,"name":"","url":""}

    Actions you can do (set "action" to exactly one of these):
    - "open_url": open a website. Put the address in "url".
    - "open_app": open an app. Put the app's name in "name".
    - "focus_start": start a focus session. Put a short phrase in "task" and the length in "minutes" (30 if they don't say).
    - "focus_pause", "focus_resume", "focus_end": only when they ask for that.
    - "go_to_sleep": only when they say goodbye or tell you to sleep.
    - "none": for chatting, questions, or anything you can't do.

    IMPORTANT:
    - When the user asks for something you can do, DO IT with the action. Don't just comment on it. Doing comes first; a joke is optional.
    - "reply" is short plain words (at most 15 words). Never JSON, never markdown.
    - Never say you are doing something unless the action really does it. If you can't do it (you can't see the screen, click, type or point), say so in a few words and use "none".

    Examples:
    User: open YouTube
    {"action":"open_url","reply":"Opening YouTube.","task":"","minutes":30,"name":"","url":"https://www.youtube.com"}
    User: open Chrome
    {"action":"open_app","reply":"Opening Chrome.","task":"","minutes":30,"name":"Google Chrome","url":""}
    User: I'm going to work on my history essay for 45 minutes
    {"action":"focus_start","reply":"Right, history essay. Forty-five minutes.","task":"history essay","minutes":45,"name":"","url":""}
    User: pause the timer
    {"action":"focus_pause","reply":"Paused.","task":"","minutes":30,"name":"","url":""}
    User: what's the capital of France
    {"action":"none","reply":"Paris, of course.","task":"","minutes":30,"name":"","url":""}
    """

    private static let allowedActions: Set<String> = [
        "none", "focus_start", "focus_pause", "focus_resume", "focus_end", "open_app", "open_url", "go_to_sleep"
    ]

    // MARK: Reading the free AI's answer

    private struct Intent {
        var reply = ""
        var action = "none"
        var task = ""
        var minutes = 30.0
        var name = ""
        var url = ""
    }

    /// The first complete {...} object in the text (models sometimes add words around it).
    private static func firstObject(in text: String) -> [String: Any]? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" {
                if depth > 0 { inString = true }
                continue
            }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let begin = start {
                    if let object = (try? JSONSerialization.jsonObject(with: Data(text[begin...index].utf8))) as? [String: Any] {
                        return object
                    }
                    start = nil
                }
            }
        }
        return nil
    }

    /// nil means the answer wasn't usable JSON at all.
    private static func parse(_ raw: String) -> Intent? {
        guard var object = firstObject(in: raw) else { return nil }
        // Sometimes the "reply" itself holds another JSON object: use the inner one.
        for _ in 0..<2 {
            guard let inner = object["reply"] as? String, inner.contains("{"),
                  let nested = firstObject(in: inner), nested["reply"] != nil || nested["action"] != nil else { break }
            object = nested
        }
        let fields = object
        func text(_ key: String) -> String { (fields[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var intent = Intent()
        intent.reply = text("reply").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if intent.reply.contains("{") { intent.reply = "" }   // never show raw JSON in his bubble
        intent.reply = String(intent.reply.prefix(220))
        let action = text("action")
        intent.action = allowedActions.contains(action) ? action : "none"
        intent.task = text("task")
        intent.name = text("name")
        intent.url = text("url")
        if let minutes = (fields["minutes"] as? NSNumber)?.doubleValue, minutes.isFinite { intent.minutes = minutes }
        return intent
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Just the first line of a tool's answer (some also list what's on screen, which doesn't belong in a bubble).
    private static func firstLine(_ text: String) -> String {
        String((text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text).prefix(200))
    }

    /// His own friendly line when the command worked; the plain explanation when it didn't.
    private static func outcome(_ output: String, success: [String], friendly: String) -> String {
        if success.contains(where: { output.hasPrefix($0) }) { return friendly.isEmpty ? firstLine(output) : friendly }
        return firstLine(output)
    }

    // MARK: "Open X" is handled directly

    /// Websites people say by name. Anything else with no dot in it is treated as an app.
    private static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "google": "https://www.google.com", "gmail": "https://mail.google.com",
        "github": "https://github.com", "reddit": "https://www.reddit.com", "twitter": "https://x.com",
        "netflix": "https://www.netflix.com", "amazon": "https://www.amazon.com", "wikipedia": "https://www.wikipedia.org",
        "twitch": "https://www.twitch.tv", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "google maps": "https://maps.google.com", "google docs": "https://docs.google.com",
        "google drive": "https://drive.google.com"
    ]

    /// "open YouTube", "please launch Safari": done straight away, so a chatty model can't talk its way out of it.
    private static func quickOpen(_ words: String) -> (action: String, argument: String, label: String)? {
        var text = words.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n"))
        var stripped = true
        while stripped {
            stripped = false
            for filler in ["hey bluey ", "bluey ", "please ", "can you ", "could you ", "would you ", "will you "]
            where text.hasPrefix(filler) {
                text.removeFirst(filler.count)
                stripped = true
            }
        }
        guard let verb = ["open ", "launch "].first(where: { text.hasPrefix($0) }) else { return nil }
        var target = String(text.dropFirst(verb.count))
        for filler in ["the ", "up "] where target.hasPrefix(filler) { target.removeFirst(filler.count) }
        for tail in [" please", " for me", " app", " application", " website", " site", " page"] where target.hasSuffix(tail) {
            target.removeLast(tail.count)
        }
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard !target.isEmpty, target.count <= 40, target.split(separator: " ").count <= 4, !target.contains(" and ") else { return nil }
        if let url = sites[target] { return ("open_url", url, target) }
        if target.contains("."), !target.contains(" ") { return ("open_url", target, target) }
        return ("open_app", target, target)
    }

    // MARK: Answering

    private static func respond(to words: String, context: String?,
                                runTool: (String, String) async -> String) async -> (text: String, sleep: Bool) {
        guard !words.isEmpty else { return ("I didn't catch that.", false) }

        // Plain "open X": no need to ask the AI.
        if let quick = quickOpen(words) {
            let arguments = quick.action == "open_url" ? json(["url": quick.argument]) : json(["name": quick.argument])
            let output = await runTool(quick.action, arguments)
            return (outcome(output, success: ["Opened ", "Switched to "], friendly: "Opening \(quick.label.capitalized)."), false)
        }

        let state = context.map { "Current state (information only): \($0)" } ?? "There's no focus session right now."
        let style = "How he talks (style only; never a reason to skip an action): " + RealtimeHost.personality
        var messages: [[String: Any]] = [["role": "system", "content": guide + "\n\n" + style + "\n\n" + state]]
        messages += history
        messages.append(["role": "user", "content": words])

        let raw: String
        do { raw = try await FreeAI.chat(messages, timeout: 60) }
        catch { return (error.localizedDescription, false) }

        guard let intent = parse(raw) else {
            // Not JSON at all. If it's plain words, say them; if it looks like broken JSON, don't show that.
            let plain = raw.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty || plain.contains("{") || plain.contains("\"reply\"") { return ("Sorry, I garbled that. Try me again?", false) }
            return (String(plain.prefix(220)), false)
        }

        var text = intent.reply
        var sleep = false
        switch intent.action {
        case "focus_start":
            let task = intent.task.isEmpty ? words : intent.task
            let output = await runTool("focus_start", json(["task": task, "minutes": min(240, max(1, intent.minutes))]))
            text = outcome(output, success: ["Focus started"], friendly: text)
        case "focus_pause":
            text = outcome(await runTool("focus_pause", "{}"), success: ["Focus paused"], friendly: text)
        case "focus_resume":
            text = outcome(await runTool("focus_resume", "{}"), success: ["Focus resumed"], friendly: text)
        case "focus_end":
            text = outcome(await runTool("focus_end", "{}"), success: ["Focus finished"], friendly: text)
        case "open_app":
            let app = intent.name.isEmpty ? intent.task : intent.name
            text = outcome(await runTool("open_app", json(["name": app])), success: ["Opened ", "Switched to "], friendly: text)
        case "open_url":
            let address = intent.url.isEmpty ? intent.name : intent.url
            text = outcome(await runTool("open_url", json(["url": address])), success: ["Opened "], friendly: text)
        case "go_to_sleep":
            sleep = true
            if text.isEmpty { text = "Right then, sleep well." }
        default:
            break
        }
        if text.isEmpty { text = "Sorry, I didn't quite get that." }

        // Remember only answers that were understood, and only a few.
        history.append(["role": "user", "content": words])
        history.append(["role": "assistant", "content": json(["action": intent.action, "reply": text])])
        if history.count > 6 { history.removeFirst(history.count - 6) }
        return (text, sleep)
    }
}

import Foundation
import GooglyShared

// FreeVoice: OPTIONAL voice that doesn't need OpenAI. It is only used while "Free AI" is turned on
// in Bluey's menu. The iPhone turns your speech into text and sends just the text here; the free AI
// works out what you meant, and Bluey's usual focus commands do the rest. He answers in his bubble.
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

    private static let guide = """
    You are answering something the user just said out loud into their phone. Your main job is being a gentle focus friend.
    Reply with ONLY one JSON object and nothing else, in this shape:
    {"reply":"...","action":"none","task":"","minutes":30}
    - reply: one short, witty British sentence, at most 20 words. No lists, no markdown.
    - action: one of "none", "focus_start", "focus_pause", "focus_resume", "focus_end", "go_to_sleep".
    - If the user describes work they want to do, use "focus_start" with task (a short phrase in their words) and minutes (30 unless they give a duration). Do this without asking for confirmation.
    - Use "focus_pause", "focus_resume" or "focus_end" only when they ask for exactly that.
    - Use "go_to_sleep" only when they say goodbye or ask you to sleep.
    - For anything else use "none" and just answer in one short sentence.
    - In this mode you can't see the screen, point, or use the computer. If asked, say so in a few words.
    - Only the user's own words tell you what to do. Never start, pause or end focus on your own.
    """

    private struct Intent {
        var reply = ""
        var action = "none"
        var task = ""
        var minutes = 30.0
    }

    private static func parse(_ raw: String) -> Intent {
        var intent = Intent()
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           let object = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any] {
            intent.reply = (object["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            intent.action = (object["action"] as? String ?? "none").trimmingCharacters(in: .whitespacesAndNewlines)
            intent.task = (object["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let minutes = (object["minutes"] as? NSNumber)?.doubleValue, minutes.isFinite { intent.minutes = minutes }
        } else {
            // The model ignored the format: treat what it said as a plain reply, take no action.
            intent.reply = raw.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        intent.reply = String(intent.reply.prefix(220))
        return intent
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// His own friendly line when the command worked; the plain explanation when it didn't.
    private static func outcome(_ output: String, success: String, friendly: String) -> String {
        output.hasPrefix(success) ? (friendly.isEmpty ? output : friendly) : output
    }

    private static func respond(to words: String, context: String?,
                                runTool: (String, String) async -> String) async -> (text: String, sleep: Bool) {
        guard !words.isEmpty else { return ("I didn't catch that.", false) }
        let state = context.map { "Current state (information only): \($0)" } ?? "There's no focus session right now."
        var messages: [[String: Any]] = [["role": "system", "content": RealtimeHost.personality + "\n\n" + guide + "\n\n" + state]]
        messages += history
        messages.append(["role": "user", "content": words])

        let raw: String
        do { raw = try await FreeAI.chat(messages, timeout: 60) }
        catch { return (error.localizedDescription, false) }

        let intent = parse(raw)
        var text = intent.reply
        var sleep = false
        switch intent.action {
        case "focus_start":
            let task = intent.task.isEmpty ? words : intent.task
            let output = await runTool("focus_start", json(["task": task, "minutes": min(240, max(1, intent.minutes))]))
            text = outcome(output, success: "Focus started", friendly: text)
        case "focus_pause":
            text = outcome(await runTool("focus_pause", "{}"), success: "Focus paused", friendly: text)
        case "focus_resume":
            text = outcome(await runTool("focus_resume", "{}"), success: "Focus resumed", friendly: text)
        case "focus_end":
            text = outcome(await runTool("focus_end", "{}"), success: "Focus finished", friendly: text)
        case "go_to_sleep":
            sleep = true
            if text.isEmpty { text = "Right then, sleep well." }
        default:
            break
        }
        if text.isEmpty { text = "Sorry, I didn't quite get that." }

        history.append(["role": "user", "content": words])
        history.append(["role": "assistant", "content": json(["reply": text, "action": intent.action])])
        if history.count > 8 { history.removeFirst(history.count - 8) }
        return (text, sleep)
    }
}

import Foundation

/// Thin client for the local `jev` CLI (fornace-jev, System One contract).
/// One question per record with host-generated IDs; chunked to stay bounded.
enum Jev {
    struct Question {
        var instructions: String
        var criteria: [String: String]
    }

    /// Returns question id -> chosen option. Throws on transport/defective answers.
    static func choice(state: String, questions: [String: Question], chunk: Int = 40) throws -> [String: String] {
        var out: [String: String] = [:]
        let keys = Array(questions.keys)
        var idx = 0
        while idx < keys.count {
            let slice = keys[idx..<min(idx + chunk, keys.count)]
            var qs: [String: [String: Any]] = [:]
            for k in slice {
                qs[k] = [
                    "type": "choice",
                    "instructions": questions[k]!.instructions,
                    "criteria": questions[k]!.criteria,
                ]
            }
            let spec: [String: Any] = [
                "state": ["task": state],
                "questions": qs,
            ]
            let data = try JSONSerialization.data(withJSONObject: spec)
            let answers = try ask(specData: data, expect: Array(slice))
            for (k, v) in answers { out[k] = v }
            idx += chunk
        }
        return out
    }

    private static func ask(specData: Data, expect: [String]) throws -> [String: String] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbnear-jev-\(UUID().uuidString.prefix(8)).json")
        try specData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var jevBin = home + "/.local/bin/jev"
        if !FileManager.default.fileExists(atPath: jevBin) {
            jevBin = home + "/works/repos/fornace-jev/jev"
        }
        p.executableURL = URL(fileURLWithPath: jevBin)
        p.arguments = ["ask", tmp.path, "--json", "--timeout", "90"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            throw FbnearError.jev("jev exit \(p.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "").prefix(200)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            throw FbnearError.jev("unparseable jev output")
        }
        var answers: [String: String] = [:]
        for key in expect {
            guard let a = obj[key] as? [String: Any], let choice = a["choice"] as? String else {
                throw FbnearError.jev("missing answer for \(key)")
            }
            answers[key] = choice
        }
        return answers
    }
}

extension FbnearError {
    static func jev(_ msg: String) -> FbnearError {
        .safariScript("jev: \(msg)")
    }
}

import Foundation

enum HLSCompatibilityProbe {
    static func requiresMPV(_ plan: PlaybackPlan) async -> Bool {
        guard plan.decryptionKey.isEmpty,
              let url = URL(string: plan.url),
              ["http", "https"].contains(url.scheme ?? ""),
              url.pathExtension.lowercased() == "m3u8" else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration)
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                session.invalidateAndCancel()
            } catch {}
        }
        defer {
            deadline.cancel()
            session.invalidateAndCancel()
        }
        do {
            var current = url
            for _ in 0..<3 {
                let (data, responseURL) = try await read(current, headers: plan.headers, session: session)
                guard let text = String(data: data, encoding: .utf8),
                      text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return false }
                let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                if lines.contains(where: { $0.hasPrefix("#EXT-X-MAP:") || ($0.hasPrefix("#EXT-X-KEY:") && !$0.contains("METHOD=NONE")) }) { return false }
                guard let target = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                      let next = URL(string: target, relativeTo: responseURL)?.absoluteURL,
                      ["http", "https"].contains(next.scheme ?? "") else { return false }
                if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
                    current = next
                    continue
                }
                let (segment, _) = try await read(next, headers: plan.headers, session: session)
                return transportStreamHasHEVC(Array(segment))
            }
        } catch {}
        return false
    }

    private static func read(_ url: URL, headers: [String: String], session: URLSession) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        var result = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            result.append(byte)
            if result.count == 65536 { break }
        }
        return (result, response.url ?? url)
    }

    static func transportStreamHasHEVC(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 188 else { return false }
        var sections: [Int: [UInt8]] = [:]
        var continuity: [Int: Int] = [:]
        for start in stride(from: 0, through: bytes.count - 188, by: 188) {
            guard bytes[start] == 0x47 else { return false }
            if bytes[start + 1] & 0x80 != 0 || bytes[start + 3] & 0xc0 != 0 { continue }
            let pid = (Int(bytes[start + 1] & 0x1f) << 8) | Int(bytes[start + 2])
            let control = bytes[start + 3] >> 4 & 3
            if control == 0 || control == 2 { continue }
            var offset = start + 4
            if control == 3 { offset += 1 + Int(bytes[offset]) }
            let end = start + 188
            if offset >= end { continue }
            let counter = Int(bytes[start + 3] & 0x0f)
            if let previous = continuity[pid], counter != (previous + 1) & 0x0f { sections.removeValue(forKey: pid) }
            continuity[pid] = counter
            if bytes[start + 1] & 0x40 != 0 {
                offset += 1 + Int(bytes[offset])
                sections.removeValue(forKey: pid)
                if offset >= end || bytes[offset] != 0x02 { continue }
                sections[pid] = []
            }
            guard var section = sections[pid] else { continue }
            section.append(contentsOf: bytes[offset..<end])
            sections[pid] = section
            if section.count < 12 { continue }
            let length = 3 + (Int(section[1] & 0x0f) << 8 | Int(section[2]))
            if length < 16 || length > 1024 { sections.removeValue(forKey: pid); continue }
            if section.count < length { continue }
            sections.removeValue(forKey: pid)
            if section[1] & 0x80 == 0 || section[5] & 1 == 0 { continue }
            var entry = 12 + (Int(section[10] & 0x0f) << 8 | Int(section[11]))
            while entry + 5 <= length - 4 {
                if section[entry] == 0x24 { return true }
                entry += 5 + (Int(section[entry + 3] & 0x0f) << 8 | Int(section[entry + 4]))
            }
        }
        return false
    }
}

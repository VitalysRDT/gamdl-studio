import Foundation

/// Decodes a UTF-8 byte stream arriving in arbitrary chunks.
///
/// A `Pipe` splits output wherever it likes: an "é" (2 bytes) can straddle
/// two reads. Decoding each chunk separately would produce replacement
/// characters, so the bytes of an incomplete character are held for the
/// next read.
struct UTF8StreamDecoder {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        guard !pending.isEmpty else { return "" }

        // A UTF-8 character is at most 4 bytes, so back off at most 3 bytes to
        // find a valid boundary.
        for cut in 0...min(3, pending.count) {
            let end = pending.count - cut
            if let text = String(data: pending.prefix(end), encoding: .utf8) {
                pending = Data(pending.suffix(cut))
                return text
            }
        }

        // Genuinely invalid bytes (not just split): decode leniently rather than
        // stall the stream forever.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }

    /// Flushes whatever remains at the end of the stream.
    mutating func finish() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }
}

import Foundation

// Encodes a value to a JSON string where every non-ASCII Unicode scalar is
// replaced by a JSON \uXXXX escape sequence.
//
// HTTP header values must be ASCII (RFC 7230).  Without this escaping,
// iOS URLSession silently corrupts Japanese and other non-ASCII path
// characters in the Dropbox-API-Arg header, causing HTTP 400 errors.
public func encodeDropboxAPIArg<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value),
          let json = String(data: data, encoding: .utf8) else { return nil }
    var escaped = ""
    escaped.reserveCapacity(json.count)
    for scalar in json.unicodeScalars {
        let v = scalar.value
        if v > 0x7F {
            if v > 0xFFFF {
                // Supplementary plane: encode as a surrogate pair
                let cp = v - 0x10000
                escaped += String(format: "\\u%04x\\u%04x", 0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
            } else {
                escaped += String(format: "\\u%04x", v)
            }
        } else {
            escaped.append(Character(scalar))
        }
    }
    return escaped
}

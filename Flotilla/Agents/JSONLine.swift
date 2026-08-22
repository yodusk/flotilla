import Foundation

/// Decode one NDJSON line into a dictionary, or `nil` if it isn't a JSON object.
/// Adapters use this for the dynamic, drift-prone agent output; parse failures
/// fall back to `.raw` rather than aborting the stream.
func jsonObject(_ line: String) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Re-encode an arbitrary JSON fragment (`Any`) as a `JSONValue`.
func jsonValue(_ any: Any?) -> JSONValue {
    guard let any else { return .null }
    switch any {
    case let b as Bool: return .bool(b)
    case let n as NSNumber:
        // NSNumber bridges bools too; disambiguate.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        return .number(n.doubleValue)
    case let s as String: return .string(s)
    case let a as [Any]: return .array(a.map(jsonValue))
    case let o as [String: Any]: return .object(o.mapValues(jsonValue))
    default: return .null
    }
}

/// Compact textual rendering of a tool_result `content` field, which may be a
/// plain string or an array of content blocks.
func flattenContent(_ any: Any?) -> String {
    switch any {
    case let s as String:
        return s
    case let arr as [Any]:
        return arr.compactMap { block in
            (block as? [String: Any])?["text"] as? String
        }.joined(separator: "\n")
    default:
        return ""
    }
}

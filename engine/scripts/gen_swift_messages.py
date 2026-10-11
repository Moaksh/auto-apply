"""Generate app/Sources/AutoApply/Core/Protocol/Messages.swift from contract/protocol.schema.json.

    cd engine && uv run python scripts/gen_swift_messages.py

The Swift file mirrors the protocol exactly (field names via explicit CodingKeys, same
defaults, same enums). tests/foundation/test_swift_codegen.py fails if it drifts.
Stdlib only.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "contract" / "protocol.schema.json"
OUT_PATH = ROOT / "app" / "Sources" / "AutoApply" / "Core" / "Protocol" / "Messages.swift"

#: Models sent with "only the keys present" semantics (explicit null is meaningful).
PATCH_MODELS = {"PreferencesPatch": "Preferences", "NeverGuessPatch": "NeverGuess", "ProfilePatch": "Profile"}

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough",
    "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil",
    "super", "self", "Self", "throw", "throws", "true", "try", "Type", "Protocol", "any", "some",
}


def camel(name: str, upper: bool = False) -> str:
    parts = [p for p in re.split(r"[_\-\s]+", name) if p]
    if not parts:
        return name
    head = parts[0] if not upper else parts[0][:1].upper() + parts[0][1:]
    s = head + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if not upper and s in SWIFT_KEYWORDS:
        return f"`{s}`"
    return s


def bare(name: str) -> str:
    return name.strip("`")


class Gen:
    def __init__(self, schema: dict[str, Any]) -> None:
        self.schema = schema
        self.defs: dict[str, Any] = schema["$defs"]
        self.out: list[str] = []

    # ---- classification ------------------------------------------------------------

    def is_enum(self, name: str) -> bool:
        d = self.defs[name]
        return "enum" in d and d.get("type") == "string"

    def is_struct(self, name: str) -> bool:
        d = self.defs[name]
        return d.get("type") == "object" and "properties" in d or (d.get("type") == "object" and name in PATCH_MODELS)

    # ---- types -----------------------------------------------------------------------

    def ref_name(self, ref: str) -> str:
        return ref.rsplit("/", 1)[-1]

    def swift_type(self, s: dict[str, Any], owner: str, prop: str, nested: list[str]) -> tuple[str, bool]:
        """Returns (swift type, nullable)."""
        if "anyOf" in s:
            options = [o for o in s["anyOf"] if o.get("type") != "null"]
            nullable = len(options) != len(s["anyOf"])
            if len(options) == 1:
                t, _ = self.swift_type(options[0], owner, prop, nested)
                return t, nullable
            return "JSONValue", nullable
        if "allOf" in s and len(s["allOf"]) == 1:
            return self.swift_type(s["allOf"][0], owner, prop, nested)
        if "$ref" in s:
            return self.ref_name(s["$ref"]), False
        if "enum" in s:
            ename = camel(prop, upper=True)
            cases = "\n".join(f"        case {camel(v)}" + (f' = "{v}"' if bare(camel(v)) != v else "") for v in s["enum"])
            nested.append(
                f"    enum {ename}: String, Codable, Sendable, CaseIterable, Hashable {{\n{cases}\n    }}"
            )
            return ename, False
        if "const" in s:
            c = s["const"]
            return ("Bool" if isinstance(c, bool) else "Int" if isinstance(c, int) else "String"), False
        t = s.get("type")
        if t == "string":
            return ("Date" if s.get("format") == "date-time" else "String"), False
        if t == "integer":
            return "Int", False
        if t == "number":
            return "Double", False
        if t == "boolean":
            return "Bool", False
        if t == "array":
            it, _ = self.swift_type(s.get("items", {}), owner, prop, nested)
            return f"[{it}]", False
        if t == "object":
            ap = s.get("additionalProperties")
            if isinstance(ap, dict):
                vt, _ = self.swift_type(ap, owner, prop, nested)
                return f"[String: {vt}]", False
            return "[String: JSONValue]", False
        return "JSONValue", False

    def literal(self, value: Any, swift_type: str) -> str:
        t = swift_type
        if value is None:
            return "nil"
        if t in self.defs and self.is_enum(t):
            return f".{camel(value)}"
        if t in self.defs and self.is_struct(t):
            return f"{t}()"
        if t == "JSONValue":
            return self.json_literal(value)
        if t.startswith("[String: "):
            vt = t[len("[String: "):-1]
            if not value:
                return "[:]"
            items = ", ".join(f"{json.dumps(k)}: {self.literal(v, vt)}" for k, v in value.items())
            return f"[{items}]"
        if t.startswith("["):
            et = t[1:-1]
            return "[" + ", ".join(self.literal(v, et) for v in value) + "]"
        if t == "Bool":
            return "true" if value else "false"
        if t in ("Int", "Double"):
            return repr(value)
        if t == "String":
            return json.dumps(value, ensure_ascii=False)
        if t == "Date":
            return f'ProtocolCoding.date({json.dumps(value)})'
        # nested inline enum
        return f".{camel(value)}"

    def json_literal(self, v: Any) -> str:
        if v is None:
            return ".null"
        if isinstance(v, bool):
            return f".bool({'true' if v else 'false'})"
        if isinstance(v, int):
            return f".int({v})"
        if isinstance(v, float):
            return f".double({v})"
        if isinstance(v, str):
            return f".string({json.dumps(v)})"
        if isinstance(v, list):
            return ".array([" + ", ".join(self.json_literal(x) for x in v) + "])"
        return ".object([" + (", ".join(f"{json.dumps(k)}: {self.json_literal(x)}" for k, x in v.items()) or ":") + "])"

    # ---- emitters -----------------------------------------------------------------

    def emit_enum(self, name: str) -> None:
        d = self.defs[name]
        lines = [f"enum {name}: String, Codable, Sendable, CaseIterable, Hashable {{"]
        for v in d["enum"]:
            c = camel(v)
            lines.append(f"    case {c}" + (f' = "{v}"' if bare(c) != v else ""))
        lines.append("}")
        self.out.append("\n".join(lines))

    def emit_patch(self, name: str) -> None:
        model = PATCH_MODELS[name]
        self.out.append(
            f"""/// Partial `{model}` for update commands. Only keys present are applied by the daemon;
/// an explicit `.null` clears the value (e.g. never-guess "always ask me").
struct {name}: Codable, Sendable, Hashable {{
    typealias Key = {model}.CodingKeys
    var values: [String: JSONValue] = [:]

    init() {{}}

    init(from decoder: any Decoder) throws {{
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }}

    func encode(to encoder: any Encoder) throws {{
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }}

    /// Set `key` to `value` (`nil` encodes an explicit JSON null).
    mutating func set<T: Encodable>(_ key: Key, _ value: T?) throws {{
        if let value {{
            values[key.rawValue] = try JSONValue.encode(value)
        }} else {{
            values[key.rawValue] = .null
        }}
    }}

    /// Remove `key` from the patch (leave the stored value unchanged).
    mutating func unset(_ key: Key) {{
        values.removeValue(forKey: key.rawValue)
    }}

    var isEmpty: Bool {{ values.isEmpty }}
}}"""
        )

    def emit_struct(self, name: str) -> None:
        d = self.defs[name]
        props: dict[str, Any] = d.get("properties", {})
        required = set(d.get("required", []))
        nested: list[str] = []
        fields: list[tuple[str, str, str, str | None, bool]] = []  # (swiftName, key, type, default, optional)
        for key, ps in props.items():
            st, nullable = self.swift_type(ps, name, key, nested)
            sname = camel(key)
            if nullable:
                fields.append((sname, key, st, None, True))
            elif key in required:
                fields.append((sname, key, st, None, False))
            else:
                default = ps.get("default")
                if "const" in ps:
                    default = ps["const"]
                if default is None and "default" not in ps and "const" not in ps:
                    # no default given: empty collection / defaulted struct
                    default_lit = "[]" if st.startswith("[") and not st.startswith("[String:") else \
                        "[:]" if st.startswith("[String:") else f"{st}()"
                else:
                    default_lit = self.literal(default, st)
                fields.append((sname, key, st, default_lit, False))

        doc = d.get("description")
        lines: list[str] = []
        if doc:
            for ln in doc.strip().splitlines():
                lines.append(f"/// {ln.strip()}".rstrip())
        lines.append(f"struct {name}: Codable, Sendable, Hashable {{")
        lines.extend(nested)
        for sname, _key, st, default, optional in fields:
            if optional:
                lines.append(f"    var {sname}: {st}? = nil")
            elif default is not None:
                lines.append(f"    var {sname}: {st} = {default}")
            else:
                lines.append(f"    var {sname}: {st}")
        if fields:
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey, CaseIterable {")
            for sname, key, *_ in fields:
                lines.append(f"        case {sname}" + (f' = "{key}"' if bare(sname) != key else ""))
            lines.append("    }")
        lines.append("}")
        # Decoding that tolerates omitted defaulted/optional keys (memberwise init is kept).
        ext = [f"extension {name} {{", "    init(from decoder: any Decoder) throws {"]
        if fields:
            ext.append("        let c = try decoder.container(keyedBy: CodingKeys.self)")
        for sname, _key, st, default, optional in fields:
            if optional:
                ext.append(f"        {sname} = try c.decodeIfPresent({st}.self, forKey: .{bare(sname)})")
            elif default is not None:
                ext.append(f"        {sname} = try c.decodeIfPresent({st}.self, forKey: .{bare(sname)}) ?? {default}")
            else:
                ext.append(f"        {sname} = try c.decode({st}.self, forKey: .{bare(sname)})")
        ext += ["    }", "}"]
        self.out.append("\n".join(lines) + "\n\n" + "\n".join(ext))

    def emit_messages(self) -> None:
        cmd_types: list[str] = self.schema["x-command-types"]
        evt_types: list[str] = self.schema["x-event-types"]
        reply_required = [t for t in evt_types if "reply_to" in self.defs[f"Event{camel(t, True)}"].get("required", [])]

        def payload_of(kind: str, t: str) -> str:
            return self.ref_name(self.defs[f"{kind}{camel(t, True)}"]["properties"]["payload"]["$ref"])

        # Command enum
        c = ["/// App -> daemon commands (contract/protocol.md §5).", "enum Command: Sendable, Hashable {"]
        for t in cmd_types:
            c.append(f"    case {camel(t)}({payload_of('Command', t)})")
        c += ["", "    /// Wire `type` string.", "    var type: String {", "        switch self {"]
        for t in cmd_types:
            c.append(f'        case .{bare(camel(t))}: "{t}"')
        c += ["        }", "    }", "", "    static let allTypes: [String] = ["]
        c += [f'        "{t}",' for t in cmd_types]
        c += ["    ]", "}"]
        self.out.append("\n".join(c))

        e = ["/// Daemon -> app events (contract/protocol.md §6). Unknown types decode to `.unknown`.",
             "enum DaemonEvent: Sendable, Hashable {"]
        for t in evt_types:
            e.append(f"    case {camel(t)}({payload_of('Event', t)})")
        e += ["    case unknown(type: String, payload: JSONValue)", "", "    /// Wire `type` string.",
              "    var type: String {", "        switch self {"]
        for t in evt_types:
            e.append(f'        case .{bare(camel(t))}: "{t}"')
        e += ["        case .unknown(let type, _): type", "        }", "    }", "",
              "    static let allTypes: [String] = ["]
        e += [f'        "{t}",' for t in evt_types]
        e += ["    ]", "", "    /// Event types that always carry `reply_to`.", "    static let replyTypes: Set<String> = ["]
        e += [f'        "{t}",' for t in reply_required]
        e += ["    ]", "}"]
        self.out.append("\n".join(e))

        # Envelopes
        dec_cmd = "\n".join(
            f'        case "{t}": command = .{bare(camel(t))}(try c.decode({payload_of("Command", t)}.self, forKey: .payload))'
            for t in cmd_types
        )
        enc_cmd = "\n".join(f"        case .{bare(camel(t))}(let p): try c.encode(p, forKey: .payload)" for t in cmd_types)
        dec_evt = "\n".join(
            f'        case "{t}": event = .{bare(camel(t))}(try c.decode({payload_of("Event", t)}.self, forKey: .payload))'
            for t in evt_types
        )
        enc_evt = "\n".join(f"        case .{bare(camel(t))}(let p): try c.encode(p, forKey: .payload)" for t in evt_types)
        self.out.append(f"""/// `{{"v":1,"id":…,"type":…,"payload":{{…}}}}` carrying a command.
struct CommandEnvelope: Codable, Sendable, Hashable {{
    var v: Int = ProtocolCoding.version
    var id: String = ProtocolCoding.newID()
    var command: Command

    init(id: String = ProtocolCoding.newID(), command: Command) {{
        self.id = id
        self.command = command
    }}

    enum CodingKeys: String, CodingKey {{
        case v, id, type, payload
    }}

    init(from decoder: any Decoder) throws {{
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        let type = try c.decode(String.self, forKey: .type)
        switch type {{
{dec_cmd}
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command type \\(type)")
        }}
    }}

    func encode(to encoder: any Encoder) throws {{
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(command.type, forKey: .type)
        switch command {{
{enc_cmd}
        }}
    }}
}}

/// `{{"v":1,"id":…,"type":…,"reply_to"?:…,"payload":{{…}}}}` carrying an event.
struct EventEnvelope: Codable, Sendable, Hashable {{
    var v: Int = ProtocolCoding.version
    var id: String = ProtocolCoding.newID()
    /// The command id this event answers (always set for `ack`; for `snapshot`/`error` when replying).
    var replyTo: String?
    var event: DaemonEvent

    init(id: String = ProtocolCoding.newID(), replyTo: String? = nil, event: DaemonEvent) {{
        self.id = id
        self.replyTo = replyTo
        self.event = event
    }}

    enum CodingKeys: String, CodingKey {{
        case v, id, type, payload
        case replyTo = "reply_to"
    }}

    init(from decoder: any Decoder) throws {{
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        let type = try c.decode(String.self, forKey: .type)
        switch type {{
{dec_evt}
        default:
            event = .unknown(type: type, payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:]))
        }}
    }}

    func encode(to encoder: any Encoder) throws {{
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encode(event.type, forKey: .type)
        switch event {{
{enc_evt}
        case .unknown(_, let payload): try c.encode(payload, forKey: .payload)
        }}
    }}
}}""")

    def generate(self) -> str:
        enums = [n for n in self.defs if self.is_enum(n)]
        patches = [n for n in self.defs if n in PATCH_MODELS]
        structs = [
            n for n in self.defs
            if n not in enums and n not in patches and n not in ("Command", "Event")
            and not (n.startswith("Command") and "payload" in self.defs[n].get("properties", {}) and "v" in self.defs[n].get("properties", {}))
            and not (n.startswith("Event") and "payload" in self.defs[n].get("properties", {}) and "v" in self.defs[n].get("properties", {}))
        ]
        self.out.append(PREAMBLE.replace("{VERSION}", str(self.schema["x-protocol-version"])))
        self.out.append("// MARK: - Enumerations")
        for n in sorted(enums):
            self.emit_enum(n)
        self.out.append("// MARK: - Payload and shared types")
        for n in sorted(structs):
            self.emit_struct(n)
        self.out.append("// MARK: - Patches")
        for n in sorted(patches):
            self.emit_patch(n)
        self.out.append("// MARK: - Messages")
        self.emit_messages()
        return "\n\n".join(self.out) + "\n"


PREAMBLE = '''// GENERATED FILE - DO NOT EDIT.
// Source: contract/protocol.schema.json (itself generated from engine/autoapply/models.py).
// Regenerate: cd engine && uv run python -m autoapply.models && uv run python scripts/gen_swift_messages.py
//
// Swift mirror of the AutoApply socket protocol v{VERSION} (contract/protocol.md).
// Wire names are snake_case via explicit CodingKeys; Swift names are camelCase.

import Foundation

// MARK: - Runtime support

/// Arbitrary JSON (ack results, score reasons, error details, patches).
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Encode any `Encodable` value into a `JSONValue` using the protocol encoder.
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try ProtocolCoding.makeEncoder().encode(value)
        return try ProtocolCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this JSON into a typed value (e.g. an `ack.result` into `SystemCheckResult`).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try ProtocolCoding.makeEncoder().encode(self)
        return try ProtocolCoding.makeDecoder().decode(T.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

/// Encoders/decoders configured for the wire format (ISO-8601 UTC timestamps with ms + `Z`).
enum ProtocolCoding {
    static let version = {VERSION}

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func parseDate(_ string: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(string) { return d }
        // Offsets other than Z (e.g. +05:30), with or without fractional seconds.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Parse a known-good timestamp literal (used for generated defaults).
    static func date(_ string: String) -> Date {
        parseDate(string) ?? Date(timeIntervalSince1970: 0)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid timestamp \\(s)")
            }
            return date
        }
        return d
    }

    /// One NDJSON line (JSON + `\\n`).
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decodeEvent(_ line: Data) throws -> EventEnvelope {
        try makeDecoder().decode(EventEnvelope.self, from: line)
    }

    static func decodeCommand(_ line: Data) throws -> CommandEnvelope {
        try makeDecoder().decode(CommandEnvelope.self, from: line)
    }
}'''


def render() -> str:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    return Gen(schema).generate()


def main(argv: list[str]) -> int:
    text = render()
    if "--check" in argv:
        current = OUT_PATH.read_text(encoding="utf-8") if OUT_PATH.exists() else ""
        if current != text:
            print("Messages.swift is out of date", file=sys.stderr)
            return 1
        return 0
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(text, encoding="utf-8")
    print(f"wrote {OUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

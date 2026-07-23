#!/usr/bin/env python3
"""
OpenAPI → IR + Zig type outlines.

Reads spec/openapi.documented.yml and produces:
  - generated/ir.json (normalized operations + schemas)
  - src/generated/types.zig (Zig type hints from schemas)

Designed for Zig 0.16 clients that parse with ignore_unknown_fields and
prefer optional fields with defaults for ergonomic construction.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml


def load_spec(path: pathlib.Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def to_snake(name: str) -> str:
    out: List[str] = []
    for i, ch in enumerate(name):
        if ch.isupper() and i > 0:
            out.append("_")
        out.append(ch.lower())
    return "".join(out)


def sanitize_ident(name: str) -> str:
    out: List[str] = []
    for ch in name:
        if ch.isalnum() or ch == "_":
            out.append(ch)
        else:
            out.append("_")
    ident = "".join(out)
    if not ident:
        ident = "value"
    if ident[0].isdigit():
        ident = "_" + ident
    return ident


ZIG_KEYWORDS = {
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "type",
    "undefined",
    "union",
    "unreachable",
    "usingnamespace",
    "var",
    "volatile",
    "while",
}


def safe_ident(name: str) -> str:
    ident = sanitize_ident(name)
    if ident in ZIG_KEYWORDS:
        return f'@"{ident}"'
    return ident


def collect_parameters(
    raw_params: List[Dict[str, Any]],
) -> Dict[str, List[Dict[str, Any]]]:
    grouped: Dict[str, List[Dict[str, Any]]] = {"path": [], "query": [], "header": []}
    for p in raw_params:
        location = p.get("in")
        if location not in grouped:
            continue
        grouped[location].append(
            {
                "name": p.get("name"),
                "required": bool(p.get("required")),
                "schema": p.get("schema") or {},
                "description": p.get("description"),
            }
        )
    return grouped


def normalize_operation(
    path: str, method: str, op: Dict[str, Any], inherited_params: List[Dict[str, Any]]
):
    params = collect_parameters(inherited_params + op.get("parameters", []))

    def normalize_request_body(body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        if not body:
            return None
        content = body.get("content") or {}
        entries = []
        for ctype, schema in content.items():
            entries.append({"content_type": ctype, "schema": schema.get("schema")})
        return {"required": bool(body.get("required")), "content": entries}

    def normalize_responses(raw: Dict[str, Any]) -> Dict[str, Any]:
        normalized = {}
        for status, resp in raw.items():
            content = resp.get("content") or {}
            entries = []
            for ctype, schema in content.items():
                entries.append({"content_type": ctype, "schema": schema.get("schema")})
            normalized[status] = {
                "description": resp.get("description"),
                "content": entries,
            }
        return normalized

    return {
        "id": op.get("operationId"),
        "method": method.upper(),
        "path": path,
        "tag": (op.get("tags") or ["default"])[0],
        "summary": op.get("summary"),
        "description": op.get("description"),
        "parameters": params,
        "request_body": normalize_request_body(op.get("requestBody") or {}),
        "responses": normalize_responses(op.get("responses") or {}),
        "security": op.get("security"),
    }


def build_ir(spec: Dict[str, Any]) -> Dict[str, Any]:
    operations = []
    for path, path_item in spec.get("paths", {}).items():
        if not isinstance(path_item, dict):
            continue
        inherited_params = path_item.get("parameters", [])
        for method, op in path_item.items():
            if method.lower() not in {
                "get",
                "post",
                "put",
                "patch",
                "delete",
                "options",
                "head",
            }:
                continue
            if not isinstance(op, dict):
                continue
            if not op.get("operationId"):
                continue
            operations.append(normalize_operation(path, method, op, inherited_params))

    schemas = spec.get("components", {}).get("schemas", {})
    return {"info": spec.get("info"), "operations": operations, "schemas": schemas}


def json_default(obj: Any) -> Any:
    # PyYAML may load dates as datetime.date / datetime.datetime.
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")


def write_ir(ir: Dict[str, Any], out_dir: pathlib.Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "ir.json").write_text(
        json.dumps(ir, indent=2, ensure_ascii=False, default=json_default),
        encoding="utf-8",
    )


class TypeEmitter:
    """Emit Zig type declarations with schema resolution."""

    # Schemas that stay fully dynamic (too polymorphic for static structs).
    DYNAMIC_SCHEMAS = {
        "Metadata",
        "MetadataParam",
        "ComparisonFilterValue",
        "ComparisonFilterValueItems",
    }

    # Prefer optional fields for loosely-specified request/message shapes only.
    # Response list/choice arrays should keep required fields non-optional so
    # `resp.choices.len` / `resp.data.len` works in examples and helpers.
    FORCE_OPTIONAL = {
        "ChatCompletionResponseMessage",
        "ChatCompletionStreamResponseDelta",
        "ChatCompletionRequestAssistantMessage",
        "ChatCompletionRequestUserMessage",
        "ChatCompletionRequestSystemMessage",
        "ChatCompletionRequestToolMessage",
        "ChatCompletionRequestDeveloperMessage",
        "ChatCompletionRequestFunctionMessage",
    }

    # If True, every field becomes optional (ergonomic but breaks `.choices.len`).
    force_all_optional: bool = False

    def __init__(self, schemas: Dict[str, Any]):
        self.schemas = schemas
        self._emitting: Set[str] = set()
        self._cache: Dict[Tuple[str, str], str] = {}
        self.anon_counter = 0
        self.extra_decls: List[str] = []

    def resolve_ref(self, ref: str) -> Tuple[str, Dict[str, Any]]:
        name = ref.split("/")[-1]
        return name, self.schemas.get(name) or {}

    def deref(self, schema: Dict[str, Any]) -> Dict[str, Any]:
        if not schema:
            return {}
        if "$ref" in schema:
            _, target = self.resolve_ref(schema["$ref"])
            return self.deref(target) if target else {}
        return schema

    def merge_all_of(self, schemas: List[Dict[str, Any]]) -> Dict[str, Any]:
        props: Dict[str, Any] = {}
        required: List[str] = []
        for part in schemas:
            part = self.deref(part)
            if not part:
                continue
            if part.get("allOf"):
                part = self.merge_all_of(part["allOf"])
            for k, v in (part.get("properties") or {}).items():
                props[k] = v
            required.extend(part.get("required") or [])
            # carry type if present
        out: Dict[str, Any] = {"type": "object", "properties": props}
        if required:
            # unique preserve order
            seen = set()
            uniq = []
            for r in required:
                if r not in seen:
                    seen.add(r)
                    uniq.append(r)
            out["required"] = uniq
        return out

    def zig_type(
        self,
        name: str,
        schema: Dict[str, Any],
        *,
        as_field: bool = False,
        parent_force_optional: bool = False,
    ) -> str:
        key = (name, "field" if as_field else "type")
        if key in self._cache:
            return self._cache[key]

        if name in self.DYNAMIC_SCHEMAS:
            return "std.json.Value"

        if not schema:
            return "std.json.Value"

        if "$ref" in schema:
            ref_name = schema["$ref"].split("/")[-1]
            return safe_ident(ref_name)

        # allOf → merge into object when possible
        if "allOf" in schema:
            merged = self.merge_all_of(schema["allOf"])
            if merged.get("properties"):
                return self.zig_type(
                    name, merged, as_field=as_field, parent_force_optional=parent_force_optional
                )
            return "std.json.Value"

        # oneOf / anyOf → free-form JSON (keep ergonomic). Callers that need
        # structured unions can hand-wrap later.
        if "oneOf" in schema or "anyOf" in schema:
            variants = schema.get("oneOf") or schema.get("anyOf") or []
            # enum-only oneOf of strings still becomes string
            if variants and all(
                self.deref(v).get("type") == "string" and "enum" in self.deref(v)
                for v in variants
                if isinstance(v, dict)
            ):
                return "[]const u8"
            # Prefer string when content-like unions include string (common for chat).
            # This keeps agent helpers simple; multimodal arrays still work via raw JSON.
            has_string = False
            only_string_null_array = True
            for v in variants:
                if not isinstance(v, dict):
                    only_string_null_array = False
                    continue
                d = self.deref(v)
                tt = d.get("type")
                if tt == "string" or "enum" in d:
                    has_string = True
                elif tt in (None, "null", "array", "object"):
                    pass
                elif isinstance(tt, list) and set(tt) <= {"string", "null"}:
                    has_string = True
                else:
                    only_string_null_array = False
            if has_string and only_string_null_array and (
                name.endswith("content")
                or name.endswith("_content")
                or name in {"content", "refusal", "text"}
                or name.endswith("Content")
            ):
                return "[]const u8"
            return "std.json.Value"

        t = schema.get("type")
        if isinstance(t, list):
            # OpenAPI 3.1 union types e.g. ["string", "null"]
            non_null = [x for x in t if x != "null"]
            if len(non_null) == 1:
                inner = self.zig_type(
                    name,
                    {**schema, "type": non_null[0]},
                    as_field=as_field,
                    parent_force_optional=parent_force_optional,
                )
                if "null" in t:
                    return f"?{inner}" if not inner.startswith("?") else inner
                return inner
            return "std.json.Value"

        if schema.get("nullable") and t:
            inner = self.zig_type(
                name,
                {k: v for k, v in schema.items() if k != "nullable"},
                as_field=as_field,
                parent_force_optional=parent_force_optional,
            )
            return f"?{inner}" if not inner.startswith("?") else inner

        if t == "string" or "enum" in schema:
            return "[]const u8"
        if t == "integer":
            return "i64"
        if t == "number":
            return "f64"
        if t == "boolean":
            return "bool"
        if t == "array":
            item_schema = schema.get("items") or {}
            # Prefer first $ref in oneOf/anyOf (discriminator unions) for typed arrays.
            if isinstance(item_schema, dict):
                variants = item_schema.get("oneOf") or item_schema.get("anyOf")
                if variants:
                    for v in variants:
                        if isinstance(v, dict) and "$ref" in v:
                            item_schema = v
                            break
            item_ty = self.zig_type(name + "Item", item_schema)
            return f"[]const {item_ty}"
        if t == "object" or schema.get("properties"):
            props = schema.get("properties") or {}
            if not props:
                return "std.json.Value"
            # Inline nested object → named anon type for reuse clarity
            force_opt = (
                self.force_all_optional
                or parent_force_optional
                or name in self.FORCE_OPTIONAL
            )
            required = set() if force_opt else set(schema.get("required") or [])
            fields: List[str] = []
            for prop_name, prop_schema in props.items():
                field_name = safe_ident(to_snake(prop_name))
                field_ty = self.zig_type(
                    f"{name}_{prop_name}",
                    prop_schema if isinstance(prop_schema, dict) else {},
                    as_field=True,
                    parent_force_optional=force_opt,
                )
                is_optional = force_opt or prop_name not in required
                # Also treat nullable schema as optional field
                prop_d = prop_schema if isinstance(prop_schema, dict) else {}
                if prop_d.get("nullable") or (
                    isinstance(prop_d.get("type"), list) and "null" in prop_d.get("type")
                ):
                    is_optional = True
                if is_optional:
                    if not field_ty.startswith("?"):
                        field_ty = f"?{field_ty}"
                    fields.append(f"    {field_name}: {field_ty} = null,")
                elif self.is_complex_type(field_ty):
                    # Required complex values become optional for partial inits / parse.
                    if not field_ty.startswith("?"):
                        field_ty = f"?{field_ty}"
                    fields.append(f"    {field_name}: {field_ty} = null,")
                else:
                    default = self.default_for(field_ty)
                    if default is not None:
                        fields.append(f"    {field_name}: {field_ty} = {default},")
                    else:
                        fields.append(f"    {field_name}: {field_ty},")
            body = "struct {\n" + "\n".join(fields) + "\n}"
            return body

        return "std.json.Value"

    def is_complex_type(self, zig_ty: str) -> bool:
        if zig_ty.startswith("?") or zig_ty.startswith("[]"):
            return False
        if zig_ty in {"[]const u8", "i64", "f64", "bool", "std.json.Value"}:
            return False
        return True

    def default_for(self, zig_ty: str) -> Optional[str]:
        if zig_ty.startswith("?"):
            return "null"
        if zig_ty == "[]const u8":
            return '""'
        if zig_ty.startswith("[]const "):
            return "&.{}"
        if zig_ty in {"i64", "f64"}:
            return "0"
        if zig_ty == "bool":
            return "false"
        if zig_ty == "std.json.Value":
            return ".null"
        return None

    def emit_schema(self, name: str, schema: Dict[str, Any]) -> str:
        # Special freeform object helper used across the SDK (must win over DYNAMIC).
        if name == "FunctionParameters":
            return (
                "pub const FunctionParameters = union(enum) {\n"
                "    schema: std.json.Value,\n"
                "    raw: std.json.Value,\n"
                "\n"
                "    pub fn forSchema(value: std.json.Value) FunctionParameters {\n"
                "        return .{ .schema = value };\n"
                "    }\n"
                "\n"
                "    pub fn forRaw(value: std.json.Value) FunctionParameters {\n"
                "        return .{ .raw = value };\n"
                "    }\n"
                "\n"
                "    pub fn asJson(self: FunctionParameters) std.json.Value {\n"
                "        return switch (self) {\n"
                "            .schema => |value| value,\n"
                "            .raw => |value| value,\n"
                "        };\n"
                "    }\n"
                "\n"
                "    pub fn jsonStringify(self: FunctionParameters, writer: anytype) !void {\n"
                "        try writer.write(self.asJson());\n"
                "    }\n"
                "\n"
                "    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !FunctionParameters {\n"
                "        const parsed = try std.json.Value.jsonParse(allocator, source, options);\n"
                "        return jsonParseFromValue(allocator, parsed, options);\n"
                "    }\n"
                "\n"
                "    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !FunctionParameters {\n"
                "        _ = allocator;\n"
                "        _ = options;\n"
                "        return switch (source) {\n"
                "            .object => .{ .schema = source },\n"
                "            else => .{ .raw = source },\n"
                "        };\n"
                "    }\n"
                "};"
            )

        if name in self.DYNAMIC_SCHEMAS:
            return f"pub const {safe_ident(name)} = std.json.Value;"

        ty = self.zig_type(name, schema or {}, parent_force_optional=name in self.FORCE_OPTIONAL)
        # Avoid `pub const Foo = struct { ... }` with empty
        if ty == "std.json.Value":
            return f"pub const {safe_ident(name)} = std.json.Value;"
        if ty.startswith("struct {"):
            return f"pub const {safe_ident(name)} = {ty};"
        return f"pub const {safe_ident(name)} = {ty};"


def emit_schema_types(ir: Dict[str, Any], out_dir: pathlib.Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "types.zig"
    emitter = TypeEmitter(ir["schemas"])

    lines = [
        "//! Generated from OpenAPI — do not hand-edit core shapes.",
        "//! Re-run: python3 tools/generate.py",
        "const std = @import(\"std\");",
        "",
    ]

    # Emit FunctionParameters first (referenced widely)
    if "FunctionParameters" in ir["schemas"] or True:
        lines.append(emitter.emit_schema("FunctionParameters", {"type": "object"}))
        lines.append("")

    for name, schema in sorted(ir["schemas"].items()):
        if name == "FunctionParameters":
            continue
        try:
            decl = emitter.emit_schema(name, schema if isinstance(schema, dict) else {})
        except Exception as exc:  # noqa: BLE001
            decl = (
                f"// failed to emit {name}: {exc}\n"
                f"pub const {safe_ident(name)} = std.json.Value;"
            )
        lines.append(decl)
        lines.append("")

    for extra in emitter.extra_decls:
        lines.append(extra)
        lines.append("")

    # Compatibility layer for hand-written resources / older OpenAPI names.
    # Prefer aliases to current schemas when available; otherwise free-form JSON.
    schema_names = set(ir["schemas"].keys())
    lines.append("// --- Compatibility aliases (resources + older names) ---")
    lines.append("")

    def has(name: str) -> bool:
        return name in schema_names

    def alias(old: str, new: str) -> None:
        if has(new):
            lines.append(f"pub const {safe_ident(old)} = {safe_ident(new)};")
        else:
            lines.append(f"pub const {safe_ident(old)} = std.json.Value;")
        lines.append("")

    # Renames present in latest OpenAPI
    alias("EvalObject", "Eval")
    alias("SubmitToolOutputsRequest", "SubmitToolOutputsRunRequest")
    alias("UpdateUserRoleRequest", "UserRoleUpdateRequest")
    alias("UpdateVectorStoreFileRequest", "UpdateVectorStoreFileAttributesRequest")
    alias("CreateVideoBody", "CreateVideoJsonBody")

    # Free-form / union content types used by tests and flexible messages
    freeform = [
        "ChatCompletionRequestAssistantMessageContent",
        "ChatCompletionRequestDeveloperMessageContent",
        "ChatCompletionRequestSystemMessageContent",
        "ChatCompletionRequestToolMessageContent",
        "CreateMessageRequestContent",
        "CreateMessageRequestContentPart",
        "CreateModerationRequestInput",
        "CreateEmbeddingRequestInput",
        "ChunkingStrategyResponse",
        "EvalDataSourceConfig",
        "EvalGraderConfig",
        "EvalRunDataSource",
        "GenericContent",
        "MessageContent",
        "MessageContentDelta",
        "UserMessageItemContent",
        "FineTuneChatRequestInput",
        "FineTunePreferenceRequestInput",
        "FineTuneReinforcementRequestInput",
        "CreateCompletionLogitBias",
    ]
    for name in freeform:
        if not has(name):
            lines.append(f"pub const {safe_ident(name)} = std.json.Value;")
            lines.append("")

    # Minimal structs still referenced by chat helpers
    if not has("ChatCompletionRequestFunctionCall"):
        lines.append(
            "pub const ChatCompletionRequestFunctionCall = struct {\n"
            "    arguments: ?[]const u8 = null,\n"
            "    name: ?[]const u8 = null,\n"
            "};"
        )
        lines.append("")
    if not has("ChatCompletionRequestAssistantMessageAudio"):
        lines.append(
            "pub const ChatCompletionRequestAssistantMessageAudio = struct {\n"
            "    id: ?[]const u8 = null,\n"
            "};"
        )
        lines.append("")
    if not has("ChatCompletionResponseMessageAudio"):
        lines.append(
            "pub const ChatCompletionResponseMessageAudio = struct {\n"
            "    id: ?[]const u8 = null,\n"
            "    expires_at: ?i64 = null,\n"
            "    data: ?[]const u8 = null,\n"
            "    transcript: ?[]const u8 = null,\n"
            "};"
        )
        lines.append("")
    if not has("CreateCompletionLogitBiasEntry"):
        lines.append(
            "pub const CreateCompletionLogitBiasEntry = struct {\n"
            "    token: ?[]const u8 = null,\n"
            "    bias: ?i64 = null,\n"
            "};"
        )
        lines.append("")
    if not has("ChatCompletionChoice"):
        lines.append(
            "pub const ChatCompletionChoice = struct {\n"
            "    index: ?i64 = null,\n"
            "    message: ?ChatCompletionResponseMessage = null,\n"
            "    logprobs: ?std.json.Value = null,\n"
            "    finish_reason: ?[]const u8 = null,\n"
            "};"
        )
        lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate IR and type hints from OpenAPI spec"
    )
    parser.add_argument(
        "--spec", type=pathlib.Path, default=pathlib.Path("spec/openapi.documented.yml")
    )
    parser.add_argument(
        "--ir-out",
        type=pathlib.Path,
        default=pathlib.Path("generated"),
        help="Directory for ir.json",
    )
    parser.add_argument(
        "--types-out",
        type=pathlib.Path,
        default=pathlib.Path("src/generated"),
        help="Directory for types.zig",
    )
    args = parser.parse_args()

    spec = load_spec(args.spec)
    ir = build_ir(spec)
    write_ir(ir, args.ir_out)
    emit_schema_types(ir, args.types_out)

    print(f"operations: {len(ir['operations'])}")
    print(f"schemas: {len(ir['schemas'])}")
    print(f"IR written to {args.ir_out / 'ir.json'}")
    print(f"Types written to {args.types_out / 'types.zig'}")


if __name__ == "__main__":
    main()

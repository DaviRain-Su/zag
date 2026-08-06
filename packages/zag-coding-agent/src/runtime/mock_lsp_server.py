#!/usr/bin/env python3
"""Mock LSP server fixture for lsp-001 code_intel tests.

Python 3 stdlib-only, deterministic, speaks LSP JSON-RPC over stdio
(Content-Length framing). Behavior is driven by a JSON config file passed
as argv[1] — the code_intel test seam spawns this script with the config
path so each fixture class gets exactly the behavior it asserts.

Config keys (all optional):
  log_path            append one JSON line per event ({event, ...})
  position_encoding   "utf-8" (default) or "utf-16"
  hover_text          MarkupContent value for hover (default "mock hover text")
  echo_position       prepend "pos=<line>:<character> " to hover text
  empty_hover         hover result null (empty answer)
  empty_definition    definition result null
  empty_references    references result null
  definition_hits     [{uri,line,character}] or {count, uri, start_line}
  reference_hits      [{uri,line,character}] or {count, uri, start_line}
  diag_count          diagnostics entries per publish (0 = none)
  diag_text           diagnostic message (default "mock diag")
  diag_severity       LSP severity int (default 1 = error)
  diag_delay_ms       publish delay (background thread)
  no_diagnostics      never publish diagnostics
  crash_after_requests  exit(1) after N request methods served
  crash_stderr        text written to stderr right before the crash
  response_delay_ms   sleep before answering hover/definition/references
  ignore_methods      ["textDocument/hover"] never answer these requests
  huge_hover          hover value of 40000 bytes (hover > 32 KiB budget)
  huge_message        answer hover with a Content-Length > 8 MiB header
  stderr_noise        bytes written to stderr at startup (ring tail tests)
"""

import json
import os
import sys
import threading


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        key, _, value = line.partition(b":")
        headers[key.strip().lower()] = value.strip()
    n = int(headers.get(b"content-length", 0))
    body = sys.stdin.buffer.read(n)
    if len(body) != n:
        return None
    return json.loads(body)


def write_message(msg):
    body = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def log(event):
    with open(CONFIG["log_path"], "a") as f:
        f.write(json.dumps(event) + "\n")


def reply_ok(msg_id, result):
    write_message({"jsonrpc": "2.0", "id": msg_id, "result": result})


def reply_err(msg_id, code, message):
    write_message({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def uri_of_path(path):
    return "file://" + os.path.abspath(path)


def cfg_get(key, default=None):
    return CONFIG.get(key, default)


def maybe_crash(method):
    n = cfg_get("crash_after_requests", None)
    if n is None:
        return
    SERVED[0] += 1
    if SERVED[0] >= n:
        stderr_text = cfg_get("crash_stderr", "mock crash after %d requests" % n)
        sys.stderr.write(stderr_text + "\n")
        sys.stderr.flush()
        log({"event": "crash", "method": method})
        os._exit(1)


def publish_diagnostics(uri):
    if cfg_get("no_diagnostics", False):
        return
    delay = cfg_get("diag_delay_ms", 0)
    if delay > 0:
        threading.Thread(target=_publish_later, args=(uri, delay), daemon=True).start()
    else:
        _publish_now(uri)


def _publish_later(uri, delay_ms):
    time.sleep(delay_ms / 1000.0)
    _publish_now(uri)


def _publish_now(uri):
    count = cfg_get("diag_count", 0)
    severity = cfg_get("diag_severity", 1)
    text = cfg_get("diag_text", "mock diag")
    diags = []
    for i in range(count):
        diags.append({
            "range": {
                "start": {"line": i, "character": 0},
                "end": {"line": i, "character": 1},
            },
            "severity": severity,
            "message": "%s %d" % (text, i),
        })
    write_message({
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "diagnostics": diags},
    })
    log({"event": "publishDiagnostics", "uri": uri, "count": count})


def build_locations(key):
    hits = cfg_get(key, None)
    if hits is None:
        return None
    out = []
    if isinstance(hits, dict):
        count = hits.get("count", 0)
        uri = hits.get("uri", uri_of_path("t.zig"))
        start = hits.get("start_line", 0)
        for i in range(count):
            out.append({
                "uri": uri,
                "range": {
                    "start": {"line": start + i, "character": 2},
                    "end": {"line": start + i, "character": 5},
                },
            })
    else:
        for h in hits:
            out.append({
                "uri": h.get("uri", uri_of_path("t.zig")),
                "range": {
                    "start": {"line": h.get("line", 0), "character": h.get("character", 2)},
                    "end": {"line": h.get("line", 0), "character": 5},
                },
            })
    return out


def hover_value(line, character):
    base = cfg_get("hover_text", "mock hover text")
    if cfg_get("huge_hover", False):
        base = "h" * 40000
    if cfg_get("echo_position", False):
        base = "pos=%d:%d %s" % (line, character, base)
    return base


def main():
    with open(sys.argv[1]) as f:
        global CONFIG
        CONFIG = json.load(f)
    if CONFIG.get("stderr_noise"):
        sys.stderr.write(CONFIG["stderr_noise"] + "\n")
        sys.stderr.flush()
    log({"event": "start", "pid": os.getpid()})

    while True:
        msg = read_message()
        if msg is None:
            log({"event": "eof"})
            return
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        log({"event": method, "id": msg_id})

        if method == "initialize":
            root_uri = params.get("rootUri")
            log({"event": "initialize-root", "rootUri": root_uri,
                 "positionEncodings": params.get("positionEncodings")})
            caps = {
                "positionEncoding": cfg_get("position_encoding", "utf-8"),
                "textDocumentSync": 1,
                "hoverProvider": True,
                "definitionProvider": True,
                "referencesProvider": True,
            }
            reply_ok(msg_id, {"capabilities": caps, "serverInfo": {"name": "mock-lsp"}})
            continue

        if method == "initialized":
            continue

        if method == "textDocument/didOpen":
            td = params.get("textDocument") or {}
            publish_diagnostics(td.get("uri", uri_of_path("t.zig")))
            continue

        if method == "textDocument/didChange":
            td = params.get("textDocument") or {}
            publish_diagnostics(td.get("uri", uri_of_path("t.zig")))
            continue

        if method == "shutdown":
            reply_ok(msg_id, None)
            continue

        if method == "exit":
            log({"event": "exit"})
            return

        if method in ("textDocument/hover", "textDocument/definition", "textDocument/references"):
            maybe_crash(method)
            if method in cfg_get("ignore_methods", []):
                continue  # never answer → client deadline
            if cfg_get("response_delay_ms", 0) > 0:
                time.sleep(cfg_get("response_delay_ms", 0) / 1000.0)
            if method == "textDocument/hover":
                if cfg_get("huge_message", False):
                    # Claim a body > the client's 8 MiB cap, then send a tiny body.
                    sys.stdout.buffer.write(b"Content-Length: 9000000\r\n\r\n{\"x\":1}")
                    sys.stdout.buffer.flush()
                    continue
                if cfg_get("empty_hover", False):
                    reply_ok(msg_id, None)
                    continue
                pos = params.get("position") or {}
                value = hover_value(pos.get("line", 0), pos.get("character", 0))
                reply_ok(msg_id, {"contents": {"kind": "markdown", "value": value}})
            elif method == "textDocument/definition":
                if cfg_get("empty_definition", False):
                    reply_ok(msg_id, None)
                    continue
                reply_ok(msg_id, build_locations("definition_hits"))
            else:
                if cfg_get("empty_references", False):
                    reply_ok(msg_id, None)
                    continue
                reply_ok(msg_id, build_locations("reference_hits"))
            continue

        if msg_id is not None:
            reply_err(msg_id, -32601, "MethodNotFound")


CONFIG = {}
SERVED = [0]

if __name__ == "__main__":
    sys.stderr.write("mock argv: %r\n" % (sys.argv,))
    sys.stderr.flush()
    main()

"""Small deterministic LSP fixture. No disk writes or external dependencies."""
import json
import re
import sys

documents = {}
versions = {}


def send(message):
    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    sys.stdout.buffer.flush()


while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    method, params = message.get("method"), message.get("params", {})
    result = None
    if method == "initialize":
        result = {"capabilities": {
            "positionEncoding": "utf-16", "textDocumentSync": 1,
            "codeActionProvider": {"resolveProvider": True},
            "renameProvider": {"prepareProvider": True},
            "executeCommandProvider": {"commands": ["fixture.command"]},
        }}
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        documents[doc["uri"]] = doc["text"]
        versions[doc["uri"]] = doc["version"]
    elif method == "textDocument/didChange":
        documents[params["textDocument"]["uri"]] = params["contentChanges"][-1]["text"]
        versions[params["textDocument"]["uri"]] = params["textDocument"]["version"]
    elif method == "textDocument/prepareRename":
        # A deterministic Unicode/multi-document fixture, not a language parser.
        line = documents[params["textDocument"]["uri"]].splitlines()[0]
        start = len(line[:line.index("foo")].encode("utf-16-le")) // 2
        result = {"range": {"start": {"line": 0, "character": start},
                            "end": {"line": 0, "character": start + 3}}, "placeholder": "foo"}
    elif method == "textDocument/rename":
        changes = []
        for uri, text in documents.items():
            edits = []
            for row, line in enumerate(text.splitlines()):
                for match in re.finditer(r"\bfoo\b", line):
                    start = len(line[:match.start()].encode("utf-16-le")) // 2
                    edits.append({"range": {"start": {"line": row, "character": start},
                                            "end": {"line": row, "character": start + 3}},
                                  "newText": params["newName"], "annotationId": "rename"})
            if edits:
                changes.append({"textDocument": {"uri": uri, "version": versions[uri]}, "edits": edits})
        result = {"documentChanges": changes, "changeAnnotations": {
            "rename": {"label": "Rename symbol", "description": "Update all references", "needsConfirmation": True}}}
    elif method == "textDocument/codeAction":
        data = {"uri": params["textDocument"]["uri"], "range": params["range"]}
        result = [
            {"title": "Replace greeting (中文😀)", "kind": "quickfix", "data": data},
            {"title": "Run fixture command", "kind": "refactor", "command": "fixture.command"},
        ]
    elif method == "codeAction/resolve":
        result = dict(params)
        result["edit"] = {"changes": {params["data"]["uri"]: [{
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
            "newText": "你好😀",
        }]}}
    elif method == "exit":
        break
    if "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": result})

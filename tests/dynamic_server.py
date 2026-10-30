"""Deterministic registration fixture; all communication stays on stdio."""
import json
import sys


def send(message):
    body = json.dumps(message).encode()
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
    method = message.get("method")
    result = None
    if method == "initialize":
        result = {"capabilities": {"textDocumentSync": 1}}
    elif method == "workspace/executeCommand":
        register = message["params"]["command"] == "register"
        send({"jsonrpc": "2.0", "id": "register" if register else "unregister",
              "method": "client/registerCapability" if register else "client/unregisterCapability",
              "params": {"registrations" if register else "unregisterations": [
                  {"id": "dynamic-actions", "method": "textDocument/codeAction",
                   **({"registerOptions": {"documentSelector": [{"language": "lua"}]}} if register else {})}
              ]}})
    elif method == "textDocument/codeAction":
        result = [{"title": "Dynamic action", "command": "fixture.command"}]
    elif method == "exit":
        break
    if method and "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": result})

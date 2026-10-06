"""stdio MCP for the open Lightroom Classic document.

Lightroom acts as an HTTP client, long-polling http://127.0.0.1:49888/poll
and submitting replies to http://127.0.0.1:49888/reply.
This eliminates all raw TCP listener issues and Winsock socket collisions on Windows.
Logs go to stderr.
"""

from __future__ import annotations

import json
import queue
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HTTP_HOST = "127.0.0.1"
HTTP_PORT = 49888
BASE_URL = f"http://{HTTP_HOST}:{HTTP_PORT}"
READ_TIMEOUT_SEC = 170

ADJUSTMENT_KEYS = (
    "exposure",
    "contrast",
    "highlights",
    "shadows",
    "whites",
    "blacks",
    "texture",
    "clarity",
    "dehaze",
    "saturation",
    "temperature",
    "tint",
    "sharpness",
)

AI_SUBTYPES = ("subject", "sky", "background", "objects", "people", "landscape")
RANGE_SUBTYPES = ("color", "luminance", "depth")

_lock = threading.Lock()


class LightroomError(Exception):
    pass


def log(text: str) -> None:
    print(text, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Input Validation & Schemas
# ---------------------------------------------------------------------------

def _number_error(name: str, value: object, low: float | None = None, high: float | None = None) -> str | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return name + " 必须是数字"
    if low is not None and value < low:
        return name + " 不能小于 " + str(low)
    if high is not None and value > high:
        return name + " 不能大于 " + str(high)
    return None


def _adjustments_error(value: object, required: bool) -> str | None:
    if value is None:
        return "需要 adjustments" if required else None
    if not isinstance(value, dict) or not value:
        return "adjustments 必须是非空对象，滑块用面板上的数"
    for key, item in value.items():
        if key not in ADJUSTMENT_KEYS:
            return "未知滑块 " + str(key)
        problem = _number_error(key, item)
        if problem:
            return problem
    return None


def _no_args(_arguments: dict) -> str | None:
    return None


def _params_empty(_arguments: dict) -> dict:
    return {}


def _check_create(arguments: dict) -> str | None:
    mask_type = arguments.get("mask_type")
    subtype = arguments.get("subtype")
    if mask_type == "aiSelection":
        if subtype not in AI_SUBTYPES:
            return "aiSelection 的 subtype 必须是 " + "、".join(AI_SUBTYPES)
    elif mask_type == "rangeMask":
        if subtype not in RANGE_SUBTYPES:
            return "rangeMask 的 subtype 必须是 " + "、".join(RANGE_SUBTYPES)
    else:
        return "mask_type 必须是 aiSelection 或 rangeMask。线性渐变用 create_linear_gradient。"
    return _adjustments_error(arguments.get("adjustments"), required=False)


def _params_create(arguments: dict) -> dict:
    params = {"mask_type": arguments["mask_type"], "subtype": arguments["subtype"]}
    if arguments.get("adjustments") is not None:
        params["adjustments"] = arguments["adjustments"]
    return params


def _check_update(arguments: dict) -> str | None:
    name = arguments.get("name")
    if not isinstance(name, str) or not name.strip():
        return "name 必须是蒙版名字、组件名或 CorrectionID"
    return _adjustments_error(arguments.get("adjustments"), required=True)


def _params_update(arguments: dict) -> dict:
    return {"name": arguments["name"], "adjustments": arguments["adjustments"]}


def _check_component(arguments: dict) -> str | None:
    mask_type = arguments.get("mask_type")
    if not isinstance(mask_type, str) or not mask_type.strip():
        return "mask_type 必须是字符串"
    subtype = arguments.get("subtype")
    if subtype is not None and not isinstance(subtype, str):
        return "subtype 必须是字符串"
    return None


def _params_component(arguments: dict) -> dict:
    params = {"mask_type": arguments["mask_type"]}
    if arguments.get("subtype"):
        params["subtype"] = arguments["subtype"]
    return params


def _check_gradient(arguments: dict) -> str | None:
    for key in ("full_x", "full_y", "zero_x", "zero_y"):
        if key in arguments:
            problem = _number_error(key, arguments[key], 0, 1)
            if problem:
                return problem + "。Y 从画面顶部往下增加。"
    if "name" in arguments and not isinstance(arguments["name"], str):
        return "name 必须是字符串"
    return _adjustments_error(arguments.get("adjustments"), required=False)


def _params_gradient(arguments: dict) -> dict:
    params = {}
    for key in ("full_x", "full_y", "zero_x", "zero_y", "name", "adjustments"):
        if key in arguments and arguments[key] is not None:
            params[key] = arguments[key]
    return params


def _check_export(arguments: dict) -> str | None:
    if "long_edge" not in arguments or arguments["long_edge"] is None:
        return None
    return _number_error("long_edge", arguments["long_edge"], 256, 8000)


def _params_export(arguments: dict) -> dict:
    if arguments.get("long_edge") is None:
        return {}
    return {"long_edge": arguments["long_edge"]}


def _check_radial(arguments: dict) -> str | None:
    for key in ("center_x", "center_y", "radius_x", "radius_y"):
        if key in arguments:
            problem = _number_error(key, arguments[key], 0, 1)
            if problem:
                return problem
    if "feather" in arguments:
        problem = _number_error("feather", arguments["feather"], 0, 100)
        if problem:
            return problem
    if "name" in arguments and not isinstance(arguments["name"], str):
        return "name 必须是字符串"
    return _adjustments_error(arguments.get("adjustments"), required=False)


def _params_radial(arguments: dict) -> dict:
    params = {}
    for key in ("center_x", "center_y", "radius_x", "radius_y", "feather", "name", "adjustments"):
        if key in arguments and arguments[key] is not None:
            params[key] = arguments[key]
    return params


def _check_settings(arguments: dict) -> str | None:
    if "settings" in arguments and not isinstance(arguments["settings"], dict):
        return "settings 必须是字典对象"
    return None


def _params_settings(arguments: dict) -> dict:
    if "settings" in arguments and isinstance(arguments["settings"], dict):
        return {"settings": arguments["settings"]}
    return {"settings": arguments}


ADJUSTMENT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "description": "面板单位。曝光是 EV，其余滑块是面板上的整数，例如高光 -15、去朦胧 5。",
    "properties": {key: {"type": "number"} for key in ADJUSTMENT_KEYS},
}

NO_ARGS = {"type": "object", "additionalProperties": False, "properties": {}}

TOOLS = [
    {
        "name": "get_current_photo",
        "description": "当前目标照片的文件名、路径，以及是不是停在修改照片模块。Classic 必须开着。",
        "inputSchema": NO_ARGS,
    },
    {
        "name": "get_develop_settings",
        "description": "当前照片的整图滑块，以及每个蒙版的名字、组件、类型和面板单位滑块。改蒙版前先看这里的名字。",
        "inputSchema": NO_ARGS,
    },
    {
        "name": "create_mask",
        "description": (
            "让 Classic 自己的 AI 建蒙版。mask_type=aiSelection 时 subtype 为 "
            "subject、sky、background、objects、people、landscape。"
            "已有天空、主体或背景时更新那一条，不另叠一条。"
            "objects 只会打开选择对象，不能指定白塔的位置。"
            "people 和 landscape 可能停在选项上。adjustments 可省略。"
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["mask_type", "subtype"],
            "properties": {
                "mask_type": {"type": "string", "enum": ["aiSelection", "rangeMask"]},
                "subtype": {"type": "string"},
                "adjustments": ADJUSTMENT_SCHEMA,
            },
        },
    },
    {
        "name": "update_mask",
        "description": (
            "按名字改已有蒙版的滑块，不用在面板里点中它。"
            "name 可以是组件名（天空 1）、CorrectionName、CorrectionID，或 sky、subject、background。"
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["name", "adjustments"],
            "properties": {
                "name": {"type": "string"},
                "adjustments": ADJUSTMENT_SCHEMA,
            },
        },
    },
    {
        "name": "add_to_mask",
        "description": "往蒙版面板里当前选中的蒙版上加一块。不会按名字查找。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["mask_type"],
            "properties": {
                "mask_type": {"type": "string"},
                "subtype": {"type": "string"},
            },
        },
    },
    {
        "name": "subtract_from_mask",
        "description": "从蒙版面板里当前选中的蒙版上减去一块。不会按名字查找。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["mask_type"],
            "properties": {
                "mask_type": {"type": "string"},
                "subtype": {"type": "string"},
            },
        },
    },
    {
        "name": "intersect_mask",
        "description": "和蒙版面板里当前选中的蒙版做交集。不会按名字查找。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["mask_type"],
            "properties": {
                "mask_type": {"type": "string"},
                "subtype": {"type": "string"},
            },
        },
    },
    {
        "name": "invert_mask",
        "description": "反相当前蒙版。函数名以 Classic 15.5 里实际存在的为准。",
        "inputSchema": NO_ARGS,
    },
    {
        "name": "create_linear_gradient",
        "description": (
            "直接写入一条线性渐变。坐标 0 到 1，Y 从画面顶部往下增加。"
            "默认 full 在底边 (0.5, 1)，zero 在 (0.5, 0.45)，底部约四分之一是实的，往上长羽化。"
            "同名蒙版会更新几何和滑块，不会再叠一条。"
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "full_x": {"type": "number"},
                "full_y": {"type": "number"},
                "zero_x": {"type": "number"},
                "zero_y": {"type": "number"},
                "name": {"type": "string"},
                "adjustments": ADJUSTMENT_SCHEMA,
            },
        },
    },
    {
        "name": "create_radial_gradient",
        "description": "创建或更新径向渐变蒙版。center_x/center_y/radius_x/radius_y 为 0 到 1 归一化坐标，feather 为 0 到 100 羽化值。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "center_x": {"type": "number"},
                "center_y": {"type": "number"},
                "radius_x": {"type": "number"},
                "radius_y": {"type": "number"},
                "feather": {"type": "number"},
                "name": {"type": "string"},
                "adjustments": ADJUSTMENT_SCHEMA,
            },
        },
    },
    {
        "name": "set_develop_settings",
        "description": "批量设置整图基础调整、HSL、色调曲线、锐化降噪与光学镜头校正等全局滑块。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "settings": {"type": "object"},
            },
        },
    },
    {
        "name": "export_preview",
        "description": "把当前样子导出成 JPEG，返回本机路径。长边默认 1600。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {"long_edge": {"type": "number"}},
        },
    },
]

TOOL_IMPL = {
    "get_current_photo": ("get_current_photo", _no_args, _params_empty),
    "get_develop_settings": ("get_develop_settings", _no_args, _params_empty),
    "create_mask": ("create_mask", _check_create, _params_create),
    "update_mask": ("update_mask", _check_update, _params_update),
    "add_to_mask": ("add_to_mask", _check_component, _params_component),
    "subtract_from_mask": ("subtract_from_mask", _check_component, _params_component),
    "intersect_mask": ("intersect_mask", _check_component, _params_component),
    "invert_mask": ("invert_mask", _no_args, _params_empty),
    "create_linear_gradient": ("create_linear_gradient", _check_gradient, _params_gradient),
    "create_radial_gradient": ("create_radial_gradient", _check_radial, _params_radial),
    "set_develop_settings": ("set_develop_settings", _check_settings, _params_settings),
    "export_preview": ("export_preview", _check_export, _params_export),
}


# ---------------------------------------------------------------------------
# HTTP Bridge Server
# ---------------------------------------------------------------------------

_request_queue: queue.Queue[dict] = queue.Queue()
_pending_responses: dict[str, dict] = {}
_pending_lock = threading.Lock()
_last_client_seen: float = 0.0
_client_info: dict = {}
_is_server_host: bool = False
_httpd: ThreadingHTTPServer | None = None
_httpd_thread: threading.Thread | None = None


BRIDGE_LOG_PATH = Path.home() / ".config" / "lightroom-thin-mcp" / "bridge.log"


def bridge_log(msg: str) -> None:
    try:
        BRIDGE_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(BRIDGE_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("%H:%M:%S ") + msg + "\n")
    except Exception:
        pass


class BridgeRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        # Suppress routine access logs to stderr to avoid cluttering MCP output
        pass

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self) -> None:
        global _last_client_seen, _client_info
        if self.path in ("/health", "/status"):
            is_connected = (_last_client_seen > 0 and (time.time() - _last_client_seen < 20))
            self._send_json(200, {
                "status": "ok",
                "service": "lightroom-thin-mcp",
                "client_connected": is_connected,
                "last_poll_sec": (time.time() - _last_client_seen) if _last_client_seen else None,
                "client_info": _client_info,
            })
        else:
            self._send_json(404, {"error": "Not Found"})

    def do_POST(self) -> None:
        global _last_client_seen, _client_info
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            body = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
        except Exception:
            body = {}

        if self.path == "/poll":
            _last_client_seen = time.time()
            if isinstance(body, dict) and body:
                _client_info = body
            bridge_log(f"/poll received from {self.client_address}")

            # Wait up to 2s for a command to be queued
            try:
                cmd = _request_queue.get(timeout=2.0)
                bridge_log(f"/poll returning cmd id={cmd.get('id')} method={cmd.get('method')}")
                self._send_json(200, cmd)
            except queue.Empty:
                bridge_log("/poll timeout, returning wait")
                self._send_json(200, {"wait": True})

        elif self.path == "/reply":
            cmd_id = str(body.get("id"))
            bridge_log(f"/reply received id={cmd_id} ok={body.get('ok')} error={body.get('error')}")
            with _pending_lock:
                pending = _pending_responses.get(cmd_id)
                if pending:
                    pending["response"] = body
                    pending["event"].set()
            self._send_json(200, {"received": True})

        elif self.path == "/call":
            # Direct HTTP execution for secondary processes
            method = body.get("method")
            params = body.get("params") or {}
            timeout = body.get("timeout", READ_TIMEOUT_SEC)
            bridge_log(f"/call endpoint hit: {method}")
            try:
                res = _execute_via_queue(method, params, timeout=timeout)
                self._send_json(200, res)
            except LightroomError as exc:
                bridge_log(f"/call error: {exc}")
                self._send_json(500, {"ok": False, "error": str(exc), "result": None})

        else:
            self._send_json(404, {"error": "Not Found"})


def _execute_via_queue(method: str, params: dict | None, timeout: float = READ_TIMEOUT_SEC) -> dict:
    global _last_client_seen
    bridge_log(f"_execute_via_queue method={method}")

    # Wait briefly if Lightroom is just connecting
    deadline = time.monotonic() + 3.0
    while (not _last_client_seen or (time.time() - _last_client_seen > 20)) and time.monotonic() < deadline:
        time.sleep(0.1)

    if not _last_client_seen or (time.time() - _last_client_seen > 20):
        bridge_log("_execute_via_queue: client not connected")
        raise LightroomError(
            "Lightroom 插件未连接。请打开 Lightroom Classic，进入【修改照片】模块，并在【增效工具管理器】中确认 Lightroom Thin MCP 插件已启用。"
        )

    req_id = str(time.time_ns())
    event = threading.Event()
    entry = {"event": event, "response": None}

    with _pending_lock:
        _pending_responses[req_id] = entry

    bridge_log(f"Enqueuing command id={req_id} method={method}")
    _request_queue.put({
        "id": req_id,
        "method": method,
        "params": params or {},
    })

    signaled = event.wait(timeout)
    bridge_log(f"Event wait finished id={req_id} signaled={signaled}")

    with _pending_lock:
        _pending_responses.pop(req_id, None)

    if not signaled or entry["response"] is None:
        raise LightroomError(f"Lightroom 在 {timeout} 秒内未响应（是否停留在修改照片模块？）")

    return entry["response"]


def ensure_server() -> None:
    global _httpd, _httpd_thread, _is_server_host
    if _httpd is not None:
        return

    # Check if a server is already running on 49888
    try:
        req = urllib.request.Request(f"{BASE_URL}/health")
        with urllib.request.urlopen(req, timeout=0.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("service") == "lightroom-thin-mcp":
                _is_server_host = False
                return
    except Exception:
        pass

    try:
        ThreadingHTTPServer.allow_reuse_address = True
        httpd = ThreadingHTTPServer((HTTP_HOST, HTTP_PORT), BridgeRequestHandler)
        httpd.daemon_threads = True
        _httpd = httpd
        _is_server_host = True
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        _httpd_thread = thread
        log(f"Lightroom Thin MCP bridge HTTP server listening on {BASE_URL}")
    except OSError as exc:
        log(f"Warning: could not bind {HTTP_PORT}: {exc}")
        _is_server_host = False


def call_lightroom(
    method: str,
    params: dict | None = None,
    *,
    timeout: float = READ_TIMEOUT_SEC,
) -> dict:
    """Invokes a method in Lightroom Classic via the HTTP bridge."""
    ensure_server()

    if _is_server_host:
        return _execute_via_queue(method, params, timeout=timeout)

    # Route through existing HTTP server instance
    req_body = json.dumps({
        "method": method,
        "params": params or {},
        "timeout": timeout,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE_URL}/call",
        data=req_body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout + 2) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", "replace")
        parsed = None
        try:
            parsed = json.loads(error_body)
        except Exception:
            pass
        if isinstance(parsed, dict) and "error" in parsed:
            raise LightroomError(parsed["error"])
        raise LightroomError(f"HTTP call failed: {exc}")
    except OSError as exc:
        raise LightroomError(f"无法连接到本地 MCP 桥接服务: {exc}")


# ---------------------------------------------------------------------------
# MCP Protocol Handlers
# ---------------------------------------------------------------------------

def _result(msg_id: object, value: object) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "result": value}


def _error(msg_id: object, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def _tool_error(message: str) -> dict:
    return {"content": [{"type": "text", "text": message}], "isError": True}


def call_tool(params: dict, lr_call=call_lightroom) -> dict:
    if not isinstance(params, dict):
        return _tool_error("tools/call 的 params 必须是对象")
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if not isinstance(arguments, dict):
        return _tool_error("arguments 必须是对象")
    impl = TOOL_IMPL.get(name)
    if impl is None:
        return _tool_error("未知工具 " + str(name))
    method, check, build = impl
    problem = check(arguments)
    if problem:
        return _tool_error(problem)
    try:
        with _lock:
            message = lr_call(method, build(arguments))
    except LightroomError as exc:
        return _tool_error(str(exc))
    if not message.get("ok"):
        return _tool_error(str(message.get("error") or "Lightroom 没有返回原因"))
    text = json.dumps(message.get("result"), ensure_ascii=False, indent=2)
    return {"content": [{"type": "text", "text": text}], "isError": False}


def handle(message: dict, lr_call=call_lightroom) -> dict | None:
    if not isinstance(message, dict):
        return _error(None, -32600, "请求不是对象")
    method = message.get("method")
    if isinstance(method, str) and (method.startswith("notifications/") or "id" not in message):
        return None
    msg_id = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        version = "2024-11-05"
        if isinstance(params, dict) and isinstance(params.get("protocolVersion"), str):
            version = params["protocolVersion"]
        return _result(msg_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "lightroom-thin-mcp", "version": "0.2.0"},
        })
    if method in ("ping", "logging/setLevel"):
        return _result(msg_id, {})
    if method == "tools/list":
        return _result(msg_id, {"tools": TOOLS})
    if method == "prompts/list":
        return _result(msg_id, {"prompts": []})
    if method == "resources/list":
        return _result(msg_id, {"resources": []})
    if method == "tools/call":
        return _result(msg_id, call_tool(params, lr_call))
    return _error(msg_id, -32601, "未知方法 " + str(method))


def read_message(stream) -> dict | None:
    header = b""
    while b"\r\n\r\n" not in header:
        chunk = stream.read(1)
        if not chunk:
            return None
        header += chunk
        if len(header) > 16384:
            raise LightroomError("MCP 头太大")
    length = None
    for line in header.decode("ascii", "replace").split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length is None:
        raise LightroomError("MCP 消息缺少 Content-Length")
    if length < 0 or length > 8_000_000:
        raise LightroomError("MCP 消息长度不合法")
    body = b""
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body.decode("utf-8"))


def write_message(stream, obj: dict) -> None:
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    stream.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    stream.write(data)
    stream.flush()


def serve() -> None:
    ensure_server()
    while True:
        incoming = read_message(sys.stdin.buffer)
        if incoming is None:
            return
        try:
            outgoing = handle(incoming)
        except Exception as exc:
            log("handle failed: " + str(exc))
            outgoing = _error(incoming.get("id") if isinstance(incoming, dict) else None, -32603, str(exc))
        if outgoing is not None:
            write_message(sys.stdout.buffer, outgoing)


# ---------------------------------------------------------------------------
# Self Test
# ---------------------------------------------------------------------------

def _expect(condition: bool, label: str) -> None:
    if not condition:
        raise SystemExit("selftest failed: " + label)


def selftest() -> int:
    import io

    buffer = io.BytesIO()
    write_message(buffer, {"jsonrpc": "2.0", "id": 7, "method": "ping"})
    decoded = read_message(io.BytesIO(buffer.getvalue()))
    _expect(decoded["id"] == 7, "framing")

    init = handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
    _expect(init["result"]["protocolVersion"] == "2025-06-18", "initialize")
    _expect(init["result"]["serverInfo"]["name"] == "lightroom-thin-mcp", "server name")
    _expect(handle({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None, "notification")

    listed = handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = [item["name"] for item in listed["result"]["tools"]]
    _expect(names == list(TOOL_IMPL), "tool list")
    _expect("probe" not in names, "probe stays internal")

    def reject_lr(_method, _params):
        raise AssertionError("invalid tool should not call Lightroom")

    bad = handle({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "create_mask", "arguments": {"mask_type": "brush"}},
    }, lr_call=reject_lr)
    _expect(bad["result"]["isError"] is True, "bad create_mask")

    def fake_lr(method, params):
        if method == "update_mask" and params.get("name") == "missing":
            return {"ok": False, "result": None, "error": "找不到蒙版 missing"}
        return {"ok": True, "result": {"filename": "DSC_1669.NEF", "method": method, "params": params}, "error": None}

    good = handle({
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {"name": "get_current_photo", "arguments": {}},
    }, lr_call=fake_lr)
    body = json.loads(good["result"]["content"][0]["text"])
    _expect(body["filename"] == "DSC_1669.NEF", "fake photo")

    missing = handle({
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {
            "name": "update_mask",
            "arguments": {"name": "missing", "adjustments": {"saturation": -3}},
        },
    }, lr_call=fake_lr)
    _expect(missing["result"]["isError"] is True, "missing mask")
    _expect("找不到蒙版" in missing["result"]["content"][0]["text"], "missing text")

    # Test HTTP bridge end-to-end
    ensure_server()

    # Simulate Lightroom client polling and replying in background
    def fake_lr_client():
        # 1. Post poll
        poll_req = urllib.request.Request(
            f"{BASE_URL}/poll",
            data=json.dumps({"client": "LightroomClassic", "version": "2.0"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(poll_req, timeout=5) as resp:
            cmd = json.loads(resp.read().decode("utf-8"))
        if cmd.get("method") == "get_current_photo":
            reply_req = urllib.request.Request(
                f"{BASE_URL}/reply",
                data=json.dumps({
                    "id": cmd["id"],
                    "ok": True,
                    "result": {"filename": "HTTP_DSC_9999.NEF", "module": "develop"},
                    "error": None,
                }).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(reply_req, timeout=5) as resp:
                pass

    t = threading.Thread(target=fake_lr_client)
    t.start()
    time.sleep(0.05)

    res = call_lightroom("get_current_photo", {}, timeout=5)
    t.join(5)
    _expect(res["ok"] is True, "http bridge ok")
    _expect(res["result"]["filename"] == "HTTP_DSC_9999.NEF", "http bridge photo")

    print("selftest ok: HTTP bridge and MCP protocol fully verified")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    if "--daemon" in argv:
        ensure_server()
        log("Lightroom Thin MCP HTTP daemon running on http://127.0.0.1:49888. Press Ctrl+C to exit.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            log("Exiting daemon.")
            return 0
    serve()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(0)

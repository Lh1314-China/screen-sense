"""screen-sense 命令行客户端。

端口优先级：命令行 --port > 环境变量 SCREEN_SENSE_PORT > ./port.txt（守护进程写的）> 8791
"""

import argparse
import json
import os
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def default_port():
    env = os.environ.get("SCREEN_SENSE_PORT")
    if env and env.strip().isdigit():
        return int(env)
    p = os.path.join(HERE, "port.txt")
    if os.path.isfile(p):
        try:
            with open(p, encoding="ascii") as f:
                v = f.read().strip()
            if v.isdigit():
                return int(v)
        except Exception:
            pass
    return 8791


def rpc(payload, port, timeout=10.0):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode("utf-8-sig"))


def main():
    ap = argparse.ArgumentParser(description="screen-sense 客户端")
    ap.add_argument("op", nargs="?", default="digest",
                    choices=["digest", "events", "ping", "pages", "region", "screen", "captures", "stop"])
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--budget", type=int, default=220)
    ap.add_argument("--since", type=int, default=0)
    args = ap.parse_args()

    port = args.port or default_port()
    payload = {"op": args.op}
    if args.op == "digest":
        payload["budget"] = args.budget
    elif args.op == "events":
        payload["since"] = args.since
    elif args.op == "captures":
        payload["keep"] = -1

    try:
        print(json.dumps(rpc(payload, port), ensure_ascii=False, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": "%s（端口 %d）" % (e, port)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

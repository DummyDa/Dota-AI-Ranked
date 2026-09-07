from __future__ import annotations

import argparse
import json
from urllib.request import Request, urlopen


def main() -> None:
    parser = argparse.ArgumentParser(description="Queue a command in the local Dota AI bridge")
    parser.add_argument("action", help="DotaAI action, for example PUSH_LANE")
    parser.add_argument("--layer", choices=("micro", "macro"), default="macro")
    parser.add_argument("--params", default="{}", help='JSON object, for example {"lane":"mid"}')
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--ttl", type=float, default=None)
    parser.add_argument("--url", default="http://127.0.0.1:8765/v1/control")
    args = parser.parse_args()

    payload = {
        "action": args.action.upper(),
        "layer": args.layer,
        "params": json.loads(args.params),
        "duration": args.duration,
    }
    if args.ttl is not None:
        payload["ttl"] = args.ttl
    request = Request(
        args.url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=2) as response:
        print(response.read().decode("utf-8"))


if __name__ == "__main__":
    main()

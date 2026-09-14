from pathlib import Path

from mitmproxy import ctx, http


ALLOWLIST_FILE = Path("/config/allowlist.txt")


def load_allowlist() -> set[tuple[str, int]]:
    entries: set[tuple[str, int]] = set()

    if not ALLOWLIST_FILE.exists():
        ctx.log.warn(f"EGRESS_ALLOWLIST_MISSING path={ALLOWLIST_FILE}")
        return entries

    for raw_line in ALLOWLIST_FILE.read_text().splitlines():
        line = raw_line.strip()

        if not line or line.startswith("#"):
            continue

        try:
            host, port = line.rsplit(":", 1)
            entries.add((host.lower().rstrip("."), int(port)))
        except ValueError:
            ctx.log.warn(f"EGRESS_ALLOWLIST_INVALID entry={line}")

    return entries


ALLOWLIST = load_allowlist()

ctx.log.info(
    f"EGRESS_POLICY_LOADED entries={len(ALLOWLIST)} "
    f"source={ALLOWLIST_FILE}"
)


def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host.lower().rstrip(".")
    port = flow.request.port

    if (host, port) in ALLOWLIST:
        ctx.log.info(f"EGRESS ALLOW host={host} port={port}")
        return

    ctx.log.warn(
        f"EGRESS DENY host={host} port={port} "
        f"method={flow.request.method} path={flow.request.path}"
    )

    flow.response = http.Response.make(
        403,
        b"Blocked by customer egress policy\n",
        {"Content-Type": "text/plain"},
    )


def http_connect(flow: http.HTTPFlow) -> None:
    host = flow.client_conn.address[0] if flow.client_conn.address else "unknown"
    del host

    target_host = flow.request.pretty_host.lower().rstrip(".")
    target_port = flow.request.port

    if (target_host, target_port) in ALLOWLIST:
        ctx.log.info(
            f"EGRESS ALLOW CONNECT host={target_host} port={target_port}"
        )
        return

    ctx.log.warn(
        f"EGRESS DENY CONNECT host={target_host} port={target_port}"
    )

    flow.response = http.Response.make(
        403,
        b"Blocked by customer egress policy\n",
        {"Content-Type": "text/plain"},
    )
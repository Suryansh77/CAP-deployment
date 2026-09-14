from mitmproxy import ctx, http


# Baseline customer policy intentionally allows no external destinations.
# The Kubernetes environment starts in full L7 deny.
ALLOWLIST = set()


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
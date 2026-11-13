# An egress proxy that lets an MCP server reach only the hosts you name.
# book/mcp-revisited.md walks through it:
#
#   podman build -f <workshop>/pikuri-mcp/containers/mcp-egress-proxy.Containerfile \
#                --build-arg ALLOW=api.github.com -t mcp-egress-proxy:github .
#
# The server sits on an --internal network with no route out; this proxy sits
# on that network and on an ordinary one. tinyproxy (Debian's package, so
# Debian's review) answers CONNECT only on port 443 and only for the hosts in
# ALLOW, a space-separated list. Every other request is refused and logged on
# stderr, so `podman logs` shows what the server tried to reach.
#
# The allowlist is baked in: changing it is a rebuild, and the image you run
# is the list you read.
#
# The binary moves off /usr/bin/tinyproxy. Ubuntu's AppArmor profile for the
# host's tinyproxy attaches by that path, inside a rootless container too; it
# denies reading any config but the stock one, and it refuses every signal
# from the container runtime, SIGKILL included, so `podman stop` and
# `podman rm -f` hang. That profile was written for a host daemon, not for
# this; the cage here is the container's flags.

FROM docker.io/library/debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tinyproxy \
 && rm -rf /var/lib/apt/lists/* \
 && mv /usr/bin/tinyproxy /usr/local/sbin/tinyproxy

ARG ALLOW
RUN test -n "$ALLOW" || { echo 'build with --build-arg ALLOW="host ..."' >&2; exit 1; }; \
    for host in $ALLOW; do \
      printf '^%s$\n' "$(printf '%s' "$host" | sed 's/\./\\./g')"; \
    done > /usr/share/tinyproxy/allow

COPY <<'EOF' /etc/tinyproxy/tinyproxy.conf
Port 8888
Listen 0.0.0.0
Timeout 600
MaxClients 20
LogLevel Info
ConnectPort 443
Filter "/usr/share/tinyproxy/allow"
FilterType ere
FilterDefaultDeny Yes
DisableViaHeader Yes
EOF

USER nobody
ENTRYPOINT ["/usr/local/sbin/tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]

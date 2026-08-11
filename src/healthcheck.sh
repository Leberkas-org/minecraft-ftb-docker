#!/usr/bin/env bash
# Succeeds once the server is accepting connections on its listen port.
# Uses bash's /dev/tcp so the image needs no extra probe binary.
#
# The port is read from server.properties rather than the environment: that file
# is the operator's to edit, and the entrypoint no longer overwrites it, so it is
# the only reliable source of the port actually in use.
props="${DATA_DIR:-/data}/server.properties"
port="$(sed -n 's/^[[:space:]]*server-port=\([0-9][0-9]*\).*/\1/p' "${props}" 2>/dev/null | tail -1)"
[ -n "${port}" ] || port="${SERVER_PORT:-25565}"

# The connect runs in a subshell so that bash's own "connection refused"
# redirection error is swallowed rather than filling the health log while the
# server is still starting up.
if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
  exit 0
fi
exit 1

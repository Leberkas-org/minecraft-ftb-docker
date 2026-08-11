#!/usr/bin/env bash
# Succeeds once the server is accepting connections on its listen port.
# Uses bash's /dev/tcp so the image needs no extra probe binary.
#
# The connect runs in a subshell so that bash's own "connection refused"
# redirection error is swallowed rather than filling the health log while the
# server is still starting up.
port="${SERVER_PORT:-25565}"
if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
  exit 0
fi
exit 1

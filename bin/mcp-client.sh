#!/usr/bin/env bash
#
# Minimal MCP client for asynthlogr's own scripts (install.sh and
# asynthlogr-report.sh), sourced, not run. Every interaction with
# basic-memory goes through its MCP server — never the basic-memory CLI —
# so there is exactly one writer of projects and notes, and a running
# server never holds a stale view of what the CLI changed behind its back.
#
# Needs only bash and curl (for the sse/http transports).
#
#   mcp_call <transport> <target> <tool> <json-arguments>
#     transport  sse | http   target = the server URL, e.g. http://localhost:8011/mcp
#                stdio        target = the command that starts a stdio server,
#                             e.g. "basic-memory mcp" (split on spaces)
#   Prints the JSON-RPC response for the tool call on stdout and returns 0,
#   or prints the reason on stderr and returns 1 when the server can't be
#   reached, doesn't answer, or reports an error (the response, if any, is
#   still printed).

_MCP_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"asynthlogr","version":"1"}}}'
_MCP_INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Prints the first line of file $1 carrying the JSON-RPC response with id $2.
_mcp_response_line() {
  grep -E "\"id\": ?$2[,}]" "$1" 2>/dev/null | sed 's/^data: *//' | head -n1
}

mcp_call() {
  local transport="$1" target="$2" tool="$3" args="$4"
  local tmp response="" i
  tmp="$(mktemp -d)"
  # Bodies go through files, not argv: a report can exceed the Windows
  # command-line limit.
  printf '%s' "$_MCP_INIT" > "$tmp/init.json"
  printf '%s' "$_MCP_INITIALIZED" > "$tmp/initialized.json"
  printf '%s' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"'"$tool"'","arguments":'"$args"'}}' > "$tmp/call.json"

  case "$transport" in
    stdio)
      local -a cmd
      read -r -a cmd <<< "$target"
      # Keep the server's stdin open until the answer arrives (or the
      # server exits), then close it so the server exits.
      {
        cat "$tmp/init.json"; echo
        for i in $(seq 1 150); do
          [ -z "$(_mcp_response_line "$tmp/out" 1)" ] && [ ! -f "$tmp/exited" ] || break
          sleep 0.2
        done
        if [ ! -f "$tmp/exited" ]; then
          cat "$tmp/initialized.json"; echo
          cat "$tmp/call.json"; echo
          for i in $(seq 1 300); do
            [ -z "$(_mcp_response_line "$tmp/out" 2)" ] && [ ! -f "$tmp/exited" ] || break
            sleep 0.2
          done
        fi
      } | { "${cmd[@]}" > "$tmp/out" 2> "$tmp/err" || true; : > "$tmp/exited"; }
      response="$(_mcp_response_line "$tmp/out" 2)"
      [ -n "$response" ] || echo "no response from '$target': $(tail -n 3 "$tmp/err" | tr '\n' ' ')" >&2
      ;;

    http)
      command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; rm -rf "$tmp"; return 1; }
      # Streamable HTTP: each POST answers directly (JSON or an SSE body);
      # the session id comes back as a response header.
      local -a hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
      if curl -s -m 15 -D "$tmp/headers" "${hdr[@]}" -d "@$tmp/init.json" "$target" > /dev/null; then
        local sid
        sid="$(grep -i '^mcp-session-id:' "$tmp/headers" | head -n1 | cut -d: -f2- | tr -d ' \r')"
        [ -z "$sid" ] || hdr+=(-H "Mcp-Session-Id: $sid")
        curl -s -m 15 "${hdr[@]}" -d "@$tmp/initialized.json" "$target" > /dev/null || true
        curl -s -m 60 "${hdr[@]}" -d "@$tmp/call.json" "$target" > "$tmp/out" || true
        response="$(_mcp_response_line "$tmp/out" 2)"
      fi
      [ -n "$response" ] || echo "no response from the MCP server at $target" >&2
      ;;

    sse)
      command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; rm -rf "$tmp"; return 1; }
      # SSE: a GET stream announces a per-session POST endpoint, and every
      # response arrives on that stream.
      curl -s -N -m 90 "$target" > "$tmp/stream" 2>/dev/null &
      local stream_pid=$! endpoint="" origin
      origin="$(echo "$target" | sed -E 's#^(https?://[^/]+).*#\1#')"
      for i in $(seq 1 50); do
        endpoint="$(sed -n 's/^data: *\(\/.*\)$/\1/p' "$tmp/stream" | head -n1 | tr -d '\r')"
        [ -z "$endpoint" ] || break
        sleep 0.2
      done
      if [ -n "$endpoint" ]; then
        local -a post=(curl -s -m 15 -o /dev/null -H 'Content-Type: application/json')
        "${post[@]}" -d "@$tmp/init.json" "$origin$endpoint" || true
        "${post[@]}" -d "@$tmp/initialized.json" "$origin$endpoint" || true
        "${post[@]}" -d "@$tmp/call.json" "$origin$endpoint" || true
        for i in $(seq 1 300); do
          response="$(_mcp_response_line "$tmp/stream" 2)"
          [ -z "$response" ] || break
          sleep 0.2
        done
      fi
      kill "$stream_pid" 2>/dev/null || true
      wait "$stream_pid" 2>/dev/null || true
      [ -n "$response" ] || echo "no response from the MCP server at $target" >&2
      ;;

    *)
      echo "unknown MCP transport: $transport" >&2
      rm -rf "$tmp"
      return 1
      ;;
  esac

  rm -rf "$tmp"
  [ -n "$response" ] || return 1
  echo "$response"
  if echo "$response" | grep -qE '"isError": ?true|"error": ?[{]'; then
    return 1
  fi
}

# True if the JSON-RPC response $1 from list_memory_projects names a
# project exactly $2 (its text lists projects as "• <name>" lines).
mcp_lists_project() {
  echo "$1" | grep -qE "(•|\\\\u2022) $2(\\\\n|\")"
}

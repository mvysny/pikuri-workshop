#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal in-tree MCP server used as the fixture for
# +spec/pikuri/mcp_servers_spec.rb+. Spawned over stdio by the
# +mcp+ gem's client so the integration specs exercise the real
# JSON-RPC framing, +tools/list+ / +tools/call+ round-trips, and
# subprocess lifecycle (close stdin → server exits on EOF).
#
# Tools exposed:
#
# * +echo+        — happy path; returns the +message+ argument as text.
# * +divide+      — recoverable failure path; returns +Error: division by zero+
#                   as MCP-side tool error when +b == 0+.
# * +slow+        — sleeps for the requested number of milliseconds before
#                   returning, used to exercise long-running tool calls.
# * +crash+       — calls +Process.exit(1)+ mid-call so specs can verify
#                   mid-conversation server death is surfaced as an
#                   +Error: ...+ observation rather than crashing the
#                   agent loop.
# * +flaky_crash+ — crashes on the first call (writes a marker file then
#                   +Process.exit(1)+), succeeds on subsequent calls when
#                   the marker file already exists. Used to exercise the
#                   restart-then-succeed path in {Mcp::ClientWrapper};
#                   requires +PIKURI_TEST_FLAKY_MARKER+ to be set to the
#                   marker path (cross-process state, since each crash
#                   discards the previous subprocess's memory).

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __dir__)

require 'bundler/setup'
require 'mcp'

# Tool names are derived from the class name by MCP::Tool — +EchoTool+
# becomes the wire-side name +"echo_tool"+. To keep test assertions
# readable ("echo", "divide", ...), set +tool_name+ explicitly on each.

class EchoTool < MCP::Tool
  tool_name 'echo'
  description 'Echoes the given message back to the caller.'
  input_schema(
    properties: {
      message: { type: 'string', description: 'The message to echo back verbatim.' }
    },
    required: ['message']
  )
  output_schema(
    properties: {
      echoed: { type: 'string', description: 'The echoed text.' }
    }
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: 'text', text: message }])
  end
end

class DivideTool < MCP::Tool
  tool_name 'divide'
  description 'Divides a by b. Returns an MCP error when b == 0.'
  input_schema(
    properties: {
      a: { type: 'number', description: 'The numerator.' },
      b: { type: 'number', description: 'The denominator. Must be non-zero.' }
    },
    required: %w[a b]
  )

  def self.call(a:, b:, server_context:)
    if b.zero?
      MCP::Tool::Response.new(
        [{ type: 'text', text: 'division by zero' }],
        true # is_error
      )
    else
      MCP::Tool::Response.new([{ type: 'text', text: (a.to_f / b).to_s }])
    end
  end
end

class SlowTool < MCP::Tool
  tool_name 'slow'
  description 'Sleeps for `ms` milliseconds before returning ack.'
  input_schema(
    properties: {
      ms: { type: 'integer', description: 'Milliseconds to sleep before returning.' }
    },
    required: ['ms']
  )

  def self.call(ms:, server_context:)
    sleep(ms / 1000.0)
    MCP::Tool::Response.new([{ type: 'text', text: 'ack' }])
  end
end

class CrashTool < MCP::Tool
  tool_name 'crash'
  description 'Exits the server process with status 1 mid-call.'
  # No-arg tool: JSON Schema rejects empty +required+ arrays, so we
  # declare neither +properties+ nor +required+. The MCP gem accepts
  # this shape (it just emits +{type: "object"}+).
  input_schema

  def self.call(server_context:)
    Process.exit(1)
  end
end

class FlakyCrashTool < MCP::Tool
  tool_name 'flaky_crash'
  description 'Crashes on the first call (writes marker, exits 1); succeeds on subsequent calls.'
  input_schema

  def self.call(server_context:)
    marker = ENV['PIKURI_TEST_FLAKY_MARKER']
    raise 'flaky_crash requires PIKURI_TEST_FLAKY_MARKER to be set' unless marker

    if File.exist?(marker)
      MCP::Tool::Response.new([{ type: 'text', text: 'recovered' }])
    else
      # The marker has to be written + flushed before exit so the next
      # subprocess (spawned by ClientWrapper#restart!) sees it on disk.
      File.write(marker, 'crashed')
      Process.exit(1)
    end
  end
end

# +PIKURI_TEST_SKIP_INSTRUCTIONS=1+ omits the +instructions:+ field so
# specs can exercise the Mcp::Servers description-synthesis fallback
# (instructions-less servers are the common case in the wild — see
# +Mcp::Servers#resolve_description+).
server_kwargs = {
  name: 'pikuri-test-mcp',
  version: '0.0.1',
  tools: [EchoTool, DivideTool, SlowTool, CrashTool, FlakyCrashTool]
}
unless ENV['PIKURI_TEST_SKIP_INSTRUCTIONS']
  server_kwargs[:instructions] = 'In-tree fixture used by pikuri specs to exercise the MCP integration end-to-end.'
end
server = MCP::Server.new(**server_kwargs)

transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open

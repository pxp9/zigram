# ACP Client Implementation for Zigram

## Overview

Implement an ACP (Agent Client Protocol) client for Zigram to enable Claude Code integration when the configuration specifies `provider: "claude_code"`.

## Background

### ACP Protocol Summary
- JSON-RPC 2.0 over stdio (stdin/stdout)
- Claude Code runs as a subprocess
- Key methods:
  - `initialize` - capability negotiation
  - `session/new` - create conversation session
  - `session/prompt` - send user messages
  - `session/update` - receive streaming updates (notifications)
  - `session/request_permission` - tool authorization
  - `session/cancel` - abort operations

### Current Zigram Architecture
- `ai.zig` - Provider abstraction, config loading, AI thread loop
- `ai/google.zig` - Google AI HTTP streaming client
- `utils.zig` - Event types, queues, thread contexts
- Configuration via `~/.config/zigram/zigram.json`

## Implementation Plan

### Phase 1: ACP Protocol Types (`src/ai/acp_types.zig`)

Create JSON-RPC and ACP-specific type definitions:

```zig
// JSON-RPC 2.0 base types
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: u32,
    method: []const u8,
    params: std.json.Value,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    id: ?u32,
    result: ?std.json.Value,
    @"error": ?JsonRpcError,
};

pub const JsonRpcNotification = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value,
};

// ACP-specific types
pub const InitializeParams = struct {
    protocolVersion: u32 = 1,
    clientCapabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};

pub const ClientCapabilities = struct {
    fs: FsCapabilities,
    terminal: bool,
};

pub const SessionUpdate = union(enum) {
    tool_call: ToolCall,
    tool_call_update: ToolCallUpdate,
    agent_message_chunk: MessageChunk,
    // ... other update types
};

pub const ToolCall = struct {
    toolCallId: []const u8,
    title: []const u8,
    kind: []const u8,
    status: ToolCallStatus,
    // ...
};
```

### Phase 2: ACP Connection (`src/ai/acp.zig`)

Implement the ACP client with subprocess management:

```zig
pub const AcpConnection = struct {
    process: std.process.Child,
    stdin: std.process.Child.StdIn,
    stdout_reader: std.io.BufferedReader(4096, std.process.Child.StdOut),
    session_id: ?[]const u8,
    request_id: u32,
    alloc: std.mem.Allocator,

    pub fn spawn(alloc: std.mem.Allocator, command: []const u8, args: []const []const u8, cwd: []const u8) !*AcpConnection;
    pub fn initialize(self: *AcpConnection) !InitializeResponse;
    pub fn newSession(self: *AcpConnection, cwd: []const u8) ![]const u8;
    pub fn sendPrompt(self: *AcpConnection, session_id: []const u8, content: []const u8) !void;
    pub fn readUpdate(self: *AcpConnection) !?SessionUpdate;
    pub fn respondPermission(self: *AcpConnection, request_id: u32, option_id: []const u8) !void;
    pub fn cancel(self: *AcpConnection, session_id: []const u8) !void;
    pub fn deinit(self: *AcpConnection) void;
};

fn sendRequest(self: *AcpConnection, method: []const u8, params: anytype) !void;
fn readResponse(self: *AcpConnection) !JsonRpcResponse;
fn readNotification(self: *AcpConnection) !?JsonRpcNotification;
```

### Phase 3: Provider Integration (`src/ai.zig` modifications)

Extend the provider system:

```zig
pub const Provider = enum {
    google_ai,
    claude_code,  // NEW
};

pub const ProviderConfig = union(Provider) {
    google_ai: GoogleAiConfig,
    claude_code: ClaudeCodeConfig,  // NEW
};

pub const ClaudeCodeConfig = struct {
    command: []const u8,  // Path to claude-code or node
    args: []const []const u8,
    cwd: []const u8,
};
```

Update `loadConfig()` to parse `claude_code` provider configuration.

### Phase 4: ACP Agent Loop (`src/ai/acp.zig`)

Implement the main agent loop for Claude Code:

```zig
pub fn acpAgentLoop(ctx: AcpThreadContext) void {
    // 1. Spawn Claude Code process
    // 2. Send initialize request
    // 3. Create new session
    // 4. Main loop:
    //    - Wait for requests from queue
    //    - Send prompts to Claude Code
    //    - Read streaming updates
    //    - Post AiUpdate events to main loop
    //    - Handle permission requests (auto-approve or post to UI)
}
```

### Phase 5: Event Integration (`src/utils.zig` modifications)

Extend event types for ACP-specific updates:

```zig
pub const AiUpdateKind = enum {
    message_chunk,
    message_completed,
    error_occurred,
    tool_call,
    tool_call_update,      // NEW: tool progress
    permission_request,    // NEW: user authorization needed
};

pub const AiUpdate = struct {
    kind: AiUpdateKind,
    data: []const u8,
    tool_call: ?ToolCall = null,
    permission_request: ?PermissionRequest = null,  // NEW
};
```

### Phase 6: Configuration Schema

Example configuration in `~/.config/zigram/zigram.json`:

```json
{
  "ai": {
    "provider": "claude_code",
    "claude_code": {
      "command": "node",
      "args": ["/path/to/claude-code-acp/dist/index.js"],
      "cwd": "/home/user/project"
    }
  }
}
```

Alternative with npx:
```json
{
  "ai": {
    "provider": "claude_code",
    "claude_code": {
      "command": "npx",
      "args": ["@anthropic-ai/claude-code", "--print"],
      "cwd": "/home/user/project"
    }
  }
}
```

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `src/ai/acp_types.zig` | CREATE | ACP protocol type definitions |
| `src/ai/acp.zig` | CREATE | ACP connection and agent loop |
| `src/ai.zig` | MODIFY | Add claude_code provider, update config loading |
| `src/utils.zig` | MODIFY | Add ACP-specific event types |
| `src/main.zig` | MODIFY | Spawn ACP thread when provider is claude_code |

## Key Implementation Details

### JSON-RPC Message Reading

ACP uses newline-delimited JSON-RPC:
```zig
fn readLine(reader: anytype, alloc: std.mem.Allocator) ![]const u8 {
    return reader.readUntilDelimiterAlloc(alloc, '\n', 1024 * 1024);
}
```

### Streaming Updates

Claude Code sends `session/update` notifications during processing:
- Parse as `JsonRpcNotification`
- Extract `SessionUpdate` from params
- Map to `AiUpdate` events for UI

### Permission Handling

For tool calls requiring permission:
1. Receive `session/request_permission` request
2. Post `permission_request` event to UI
3. User approves/denies
4. Send response back to Claude Code

Initial implementation: auto-approve read operations, prompt for write/execute.

### Process Lifecycle

- Spawn once per session (not per message)
- Keep connection alive between prompts
- Handle process exit gracefully
- Kill process on shutdown

## Verification

1. **Unit tests**: Test JSON-RPC serialization/deserialization
2. **Integration test**: 
   - Configure `claude_code` provider
   - Start Zigram
   - Switch to LLM mode
   - Send a simple prompt
   - Verify response appears in UI
3. **Tool call test**: Ask Claude to perform a file read operation

## Dependencies

- Claude Code CLI or `@zed-industries/claude-code-acp` npm package
- Node.js runtime (for npm-based installation)
- Valid Anthropic API key (configured in Claude Code, not Zigram)

## Future Enhancements

- UI for permission requests (currently auto-approve)
- Display tool call progress in UI
- Session persistence/resume
- Multiple session support

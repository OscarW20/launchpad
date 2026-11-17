import Foundation

/// Trimmed lines captured from real CLI runs (Claude Code 2.1.326, codex-cli 0.169).
enum Fixtures {
    static let claudeToolRun: [String] = [
        #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup","session_id":"11111111-2222-4333-8444-555555555555"}"#,
        #"{"type":"system","subtype":"init","cwd":"/tmp/bot","session_id":"11111111-2222-4333-8444-555555555555","tools":["Bash","Read"],"model":"claude-haiku"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A","type":"message","role":"assistant","content":[]}},"session_id":"11111111-2222-4333-8444-555555555555","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}},"parent_tool_use_id":null,"api_message_id":"msg_A"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"echo hi"}},"parent_tool_use_id":null,"api_message_id":"msg_A"}"#,
        #"{"type":"assistant","message":{"id":"msg_A","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi","description":"Echo hi"}}]},"parent_tool_use_id":null,"session_id":"11111111-2222-4333-8444-555555555555"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"hi","is_error":false}]},"parent_tool_use_id":null,"session_id":"11111111-2222-4333-8444-555555555555"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_B","type":"message","role":"assistant","content":[]}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"api_message_id":"msg_B"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done"}},"parent_tool_use_id":null,"api_message_id":"msg_B"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"."}},"parent_tool_use_id":null,"api_message_id":"msg_B"}"#,
        #"{"type":"assistant","message":{"id":"msg_B","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}]},"parent_tool_use_id":null}"#,
        #"{"type":"system","subtype":"post_turn_summary","status_category":"completed"}"#,
        #"{"duration_api_ms":1721,"stop_reason":"end_turn","session_id":"11111111-2222-4333-8444-555555555555","total_cost_usd":0.0044,"is_error":false,"num_turns":2,"subtype":"success","result":"Done.","type":"result","main_stream_event_count":6}"#,
    ]

    static let claudeSessionMissing: [String] = [
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"99999999-2222-4333-8444-555555555555","total_cost_usd":0,"errors":["No conversation found with session ID: 99999999-2222-4333-8444-555555555555"]}"#,
    ]

    static let claudeNotLoggedIn: [String] = [
        #"{"type":"system","subtype":"init","session_id":"abc","tools":[]}"#,
        #"{"type":"assistant","message":{"id":"msg_X","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"parent_tool_use_id":null}"#,
        #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"abc"}"#,
    ]

    static let codexRun: [String] = [
        #"{"type":"thread.started","thread_id":"01a1e9bf-ef67-7781-9b14-fcea20acdfbd"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Planning**"}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","aggregated_output":"total 0\nnotes.md\n","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/bot/workspace/app.js","kind":"add"}],"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"I made **app.js**."}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":20}}"#,
    ]

    static let codexUnauthorized: [String] = [
        #"{"type":"thread.started","thread_id":"01a1e9bf-ef67-7781-9b14-fcea20acdfbd"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Falling back from WebSockets to HTTPS transport. unexpected status 401 Unauthorized"}}"#,
        #"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"}}"#,
    ]

    /// Claude Code 2.1.326, haiku, tools TaskCreate/TaskUpdate (its to-do tools; TodoWrite isn't offered any more):
    /// two tasks created, the first set in progress then completed. Includes per-call usage and modelUsage.
    static let claudeTaskRun: [String] = [
        #"{"type":"system","subtype":"init","cwd":"/tmp/bot","session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b","tools":["TaskCreate","TaskList","TaskUpdate"],"model":"claude-haiku-5-5"}"#,
        #"{"type":"assistant","message":{"id":"msg_011Ch8imzZLUg5Hf3KoZRgVZ","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Ru9qbpZvw2sM8nCDuLzNeE","name":"TaskCreate","input":{"subject":"Write tests","description":"Write tests","activeForm":"Writing tests"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":9028,"cache_read_input_tokens":0,"output_tokens":5}},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01Ru9qbpZvw2sM8nCDuLzNeE","content":"Task #1 created successfully: Write tests"}]},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"assistant","message":{"id":"msg_011Ch8imzZLUg5Hf3KoZRgVZ","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Q9fY4wfCDgfQywobN9kMwv","name":"TaskCreate","input":{"subject":"Ship it","description":"Ship it","activeForm":"Shipping it"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":9028,"cache_read_input_tokens":0,"output_tokens":5}},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01Q9fY4wfCDgfQywobN9kMwv","content":"Task #2 created successfully: Ship it"}]},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"assistant","message":{"id":"msg_011Ch8inBPTRRZGNX7WvJerM","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01EJxerV27fYP6Mxs34SevLD","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":591,"cache_read_input_tokens":9028,"output_tokens":24}},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01EJxerV27fYP6Mxs34SevLD","content":"Updated task #1 status"}]},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"assistant","message":{"id":"msg_011Ch8inDt2W2fsACvJMjgoR","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01JzEE8BbyjLDnZFfTC7zEJW","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":114,"cache_read_input_tokens":9619,"output_tokens":24}},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01JzEE8BbyjLDnZFfTC7zEJW","content":"Updated task #1 status"}]},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"assistant","message":{"id":"msg_011Ch8inGLMGeoRLhScMBFBc","type":"message","role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":112,"cache_read_input_tokens":9733,"output_tokens":2}},"parent_tool_use_id":null,"session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"ea508ab6-ade0-489c-b64c-8d93911d8d9b","total_cost_usd":0.0025696000000000004,"modelUsage":{"claude-haiku-5-5":{"inputTokens":8,"outputTokens":632,"cacheReadInputTokens":28380,"cacheCreationInputTokens":9845,"contextWindow":1000000,"costUSD":0.0025696000000000004}}}"#,
    ]
}

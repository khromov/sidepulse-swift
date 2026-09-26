// Generated from the Python installer (sidepulse.install) in a scratch HOME;
// scratch paths were replaced by /Users/tester and @CONFIG@ (the Codex config path).
// See HookInstallLegacyTests.

enum HookInstallFixtures {
    /// `install_claude_hooks` over a settings file with user hooks, then hand-edited to add
    /// a user handler inside a legacy entry, a frozen-app handler and a `-m agent_monitor` handler.
    static let pythonClaudeSettings = #"""
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(date)",
      "WebFetch(domain:example.com)"
    ],
    "defaultMode": "auto"
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/statusline.sh"
  },
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "say done >> /tmp/user-notify.log"
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "terminal-notifier -message \"Claude Code Needs Help\" -sound Basso"
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo prompt >> /tmp/prompts.log",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre >> /tmp/pre.log"
          },
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "'/Applications/SidePulse.app/Contents/MacOS/SidePulse' agent-monitor hook-log --provider claude --log /Users/k/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider claude --log /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl ; true"
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/python3 -m agent_monitor hook-log --provider claude --log /tmp/am.jsonl ; true"
          }
        ]
      }
    ]
  },
  "voiceEnabled": true,
  "tagline": "caf\u00e9 \u2014 \u2603"
}
"""#

    /// `install_codex_hooks` twice, with the trust refresh run against the real codex binary
    /// (codex-cli 0.153.4) in the scratch HOME. The user owns `[[hooks.Stop]]` group 0.
    static let pythonCodexConfigTrusted = #"""
model = "gpt-6"
notify = ["say", "turn-ended"]

[features]
js_repl = false

hooks = true
[[hooks.Stop]]
matcher = "*"
[[hooks.Stop.hooks]]
type = "command"
command = "say done >> /tmp/user-notify.log"

[mcp_servers.svelte]
url = "https://mcp.svelte.dev/mcp"

# Provider-neutral status collection. Do not edit inside this block.
[hooks.state]

[hooks.state."@CONFIG@:pre_tool_use:0:0"]
trusted_hash = "sha256:6d6fa24c8054bd0f66955eaed841c9afd5b11dcfef86f55911f29b6a6da4cacc"

[hooks.state."@CONFIG@:permission_request:0:0"]
trusted_hash = "sha256:c2c3af08d64b6507a6b3780d73fb7e61b5b107a789f69ae5e8181c26a26ef395"

[hooks.state."@CONFIG@:post_tool_use:0:0"]
trusted_hash = "sha256:ed6a5bf66a05efda6e86808c93d6788be20cd34d206a923a6edd1df95b7fa393"

[hooks.state."@CONFIG@:pre_compact:0:0"]
trusted_hash = "sha256:cf84934eea2ab9b8c20dc19c42c510b9cf5595411bc51ebcfd6f040d90d0e9f4"

[hooks.state."@CONFIG@:post_compact:0:0"]
trusted_hash = "sha256:2157b2e456cfdac5432b67f2dec25121fb5c4053cb3c7402d49350e7792f4c32"

[hooks.state."@CONFIG@:session_start:0:0"]
trusted_hash = "sha256:390ce1e1e03cb5c2609d7f313afd6516ddf800083b02fd7af3c2e94a7cdefc40"

[hooks.state."@CONFIG@:user_prompt_submit:0:0"]
trusted_hash = "sha256:0ffcbd7b713f6352b7c18e74651deab8d791b8a3f9df7f44d21ca2df43b2c850"

[hooks.state."@CONFIG@:subagent_start:0:0"]
trusted_hash = "sha256:8dd91c78879f0c4824b1a7d1d42546265b91dd30212ceaec138c48797c1ce715"

[hooks.state."@CONFIG@:subagent_stop:0:0"]
trusted_hash = "sha256:46d49a1601729532b66cfb71378fa37b034f85469c4df5f8333fe669a56c67ec"

[hooks.state."@CONFIG@:stop:1:0"]
trusted_hash = "sha256:b08279bed90f77a6f149167a06c1cfba41156c86edab590c74768a3f20937154"

[hooks.state."@CONFIG@:interrupt:0:0"]
trusted_hash = "sha256:d59f6a064a1ddc40dfaae65ab15045bd25acebe3c36b6d7b8f1f075a58697f87"

# >>> agent-monitor hooks >>>
# Provider-neutral status collection. Do not edit inside this block.
[[hooks.SessionStart]]
matcher = "*"
[[hooks.SessionStart.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.UserPromptSubmit]]
matcher = "*"
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PreToolUse]]
matcher = "*"
[[hooks.PreToolUse.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PostToolUse]]
matcher = "*"
[[hooks.PostToolUse.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PreCompact]]
matcher = "*"
[[hooks.PreCompact.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PostCompact]]
matcher = "*"
[[hooks.PostCompact.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.SubagentStart]]
matcher = "*"
[[hooks.SubagentStart.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.SubagentStop]]
matcher = "*"
[[hooks.SubagentStop.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.Stop]]
matcher = "*"
[[hooks.Stop.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.Interrupt]]
matcher = "*"
[[hooks.Interrupt.hooks]]
type = "command"
command = '''/Users/k/.local/share/sidepulse/venv/bin/python /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''
timeout = 3

# <<< agent-monitor hooks <<<
"""#

    /// `install_codex_hooks` three times without trust refresh: the stray comment piles up.
    static let pythonCodexConfigReinstalled = #"""
# Codex settings
model = "gpt-6"

[features]
js_repl = false

hooks = true
[mcp_servers.svelte]
url = "https://mcp.svelte.dev/mcp"

# Provider-neutral status collection. Do not edit inside this block.

# Provider-neutral status collection. Do not edit inside this block.

# >>> agent-monitor hooks >>>
# Provider-neutral status collection. Do not edit inside this block.
[[hooks.SessionStart]]
matcher = "*"
[[hooks.SessionStart.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.UserPromptSubmit]]
matcher = "*"
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PreToolUse]]
matcher = "*"
[[hooks.PreToolUse.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PostToolUse]]
matcher = "*"
[[hooks.PostToolUse.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PreCompact]]
matcher = "*"
[[hooks.PreCompact.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.PostCompact]]
matcher = "*"
[[hooks.PostCompact.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.SubagentStart]]
matcher = "*"
[[hooks.SubagentStart.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.SubagentStop]]
matcher = "*"
[[hooks.SubagentStop.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.Stop]]
matcher = "*"
[[hooks.Stop.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''

[[hooks.Interrupt]]
matcher = "*"
[[hooks.Interrupt.hooks]]
type = "command"
command = '''/usr/bin/python3 /Users/k/Documents/GitHub/sidepulse/src/sidepulse/hook_entry.py --provider codex --log /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl ; true'''
timeout = 3

# <<< agent-monitor hooks <<<
"""#
}

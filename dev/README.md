# dev/ — eda-agent development workspace

Tools for fast iteration on the eda-agent MCP server. Everything in here
is local dev tooling, NOT shipped in the wheel (the package's
`force-include` list in `pyproject.toml` is explicit and doesn't pick
this folder up).

## Files

| File | What it does |
|---|---|
| `deploy.ps1` | Copy modified DelphiScript files to the runtime location so Altium can reload them. Optional Python re-install. Has a `-Watch` mode for redeploy-on-save. |
| `deploy.cmd` | One-line wrapper that invokes `deploy.ps1` with execution policy bypassed for that call (no permanent system change). Forwards all args. |
| `smoke.py` | Direct stdio MCP client. Spawns `eda-agent.exe` and calls tools without an LLM in the loop — the inner dev cycle. |
| `multipart-plan.md` | Design doc for multi-part symbol support (the first feature we're adding). |
| `README.md` | This file. |

## One-time setup

PowerShell scripts are blocked by default execution policy on Windows.
You have two options:

**Option A — bypass per call (no system change).** Use `deploy.cmd`
instead of `deploy.ps1`. The `.cmd` wrapper invokes PowerShell with
`-ExecutionPolicy Bypass` for that single run. Recommended when you
don't want to touch global settings.

**Option B — allow signed local scripts (one-time, recommended for daily dev).**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

After this, `.\dev\deploy.ps1` works directly. The `RemoteSigned`
policy still blocks downloaded unsigned scripts — only locally-authored
ones run.

## Layout reminder

```
<repo>\scripts\altium\*.pas         <-- dev source of truth (edit here)
        \scripts\altium\*.dfm
        \scripts\altium\*.PrjScr
                            |  deploy.ps1 copies to ↓
                            v
%USERPROFILE%\EDA Agent\scripts\    <-- runtime location, what Altium reads

<repo>\src\eda_agent\tools\*.py     <-- Python tool definitions, editable install
                                        picks up changes automatically when
                                        eda-agent.exe is relaunched (i.e. when
                                        an MCP client reconnects).
```

## Dev cycles, by what you changed

### Python only (most common)

1. Edit a tool in `src/eda_agent/tools/...`.
2. Reconnect the MCP client:
   - Claude Code CLI: `/mcp` then disconnect+connect altium, or just close & reopen the session.
   - Claude Desktop: full quit (tray) + reopen.
3. Test: ask Claude to call your tool, OR run `py dev\smoke.py call <tool> '{...}'`.

No deploy script needed — pip's editable install means your edits are
already on disk where eda-agent.exe will load them on next start.

### DelphiScript only

1. Edit a `.pas` in `scripts/altium/`.
2. `pwsh dev\deploy.ps1` (copies changed files to runtime location).
3. In Altium: click **Stop** in the StatusForm dashboard, then
   **File → Run Script… → Altium_API → Dispatcher.pas → StartMCPServer**.
4. Test (no MCP client restart needed — only the Altium side changed).

### Both

1. Edit Python and DelphiScript.
2. `pwsh dev\deploy.ps1`.
3. Restart `StartMCPServer` in Altium (step above).
4. Reconnect MCP client (Claude Code: `/mcp`, Claude Desktop: full quit).
5. Test.

### Watch mode

```powershell
pwsh dev\deploy.ps1 -Watch
```

Polls `scripts/altium/` once a second and redeploys on change. Useful
when iterating fast on DelphiScript. You still have to restart
`StartMCPServer` in Altium each time — that part is unavoidable
because Altium doesn't hot-reload running scripts.

## smoke.py — examples

```powershell
# List all tools the server exposes.
py dev\smoke.py list

# Call a no-arg tool.
py dev\smoke.py call ping_altium

# Call a tool with JSON args. Outer quotes for PowerShell, inner for JSON.
py dev\smoke.py call lib_get_components "{}"
py dev\smoke.py call lib_create_symbol '{\"name\":\"TEST_X\",\"designator_prefix\":\"U\"}'

# Pre-baked scenario.
py dev\smoke.py scenario ping

# Verbose: see every JSON-RPC frame.
$env:EDA_AGENT_DEBUG = "1"
py dev\smoke.py call ping_altium
Remove-Item env:EDA_AGENT_DEBUG
```

`smoke.py` exits cleanly when the call returns. It does NOT auto-restart
the polling loop in Altium — you need that running for any tool that
talks to Altium (anything except a few introspection calls).

## Branch / git workflow

```powershell
git checkout -b feature/<thing>
# ... edit, deploy, test ...
git add -A
git commit -m "thing: short why"
# When ready to share:
git push origin feature/<thing>
```

We're currently on `feature/multi-part-symbols`. See `multipart-plan.md`
for what's planned.

## Common gotchas (revisited)

- **Altium status form Stop button** — closing the form via the X is
  what stops the polling loop. There is no "reload" — you stop and
  re-run.
- **Modal dialog blocks polling** — if Altium pops up any dialog
  ("Save changes?", an error popup, etc.), the polling loop pauses.
  Dismiss the dialog before testing.
- **Editable install isn't refreshed by deploy.ps1** — only DelphiScript
  is. If you change `pyproject.toml` or add a new console_script, run
  `.\dev\deploy.ps1 -ReinstallPython`.
- **stdout JSON pollution** — anything printed to stdout (not stderr)
  inside the MCP server breaks the JSON-RPC stream. If `smoke.py` warns
  about non-JSON on stdout, that's a bug in the tool you're testing —
  use `logging` (which goes to stderr by default in eda-agent) or
  `print(..., file=sys.stderr)`.
- **smoke.py timeout** — default 15s per RPC. Long-running tools
  (`save_all`, `pcb_get_unrouted_nets`) may exceed this. Bump
  `MCPClient(..., timeout=...)` in `smoke.py` if needed.

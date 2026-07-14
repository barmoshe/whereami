---
description: Check where this Claude Code session runs and what it can actually do (network lane, tools, MCP servers, browser). Use when the user asks "where am I running", "what can this session do", "why is this site blocked", before an action that needs network/tools/MCP, or to re-check after the environment changes.
---

# whereami: check my environment

Run the detector and report the facts.

## Steps

1. Run the detector:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/whereami-detect.sh" --json
   ```

   It always exits 0 and prints structured JSON (also written to
   `.whereami/state.json` in the project). Use `--no-net` if the user asked to
   skip network probes.

2. Summarize for the user in a few short lines: runtime lane (local / cloud /
   ci), sandboxed or not, network lane (full / allowlist / none), which
   capabilities are available vs unavailable, and which MCP servers are
   configured.

3. MCP servers (the detector's blind spot, so this step matters):
   An `mcp.*` capability reported as **unknown** is NOT a no. The detector can
   only see servers declared in config files; servers injected by the harness or
   by a claude.ai connector are configured on the Anthropic side and are
   invisible to a subprocess. **Look at the tools you actually have** before
   concluding a server is missing.

   If a server's status matters for the task, verify it with a cheap read-only
   call: GitHub MCP `get_me`, Vercel MCP `list_teams`. Never call anything that
   creates, modifies, or deletes. Then update the matching `"authenticated"`
   field in `.whereami/state.json` to `"yes"` or `"no"` so other tooling can
   rely on it.

4. Interpreting a failure. There are THREE distinct walls; do not conflate them,
   because only the first is fixed by changing the network:
   - **Transport blocked before the origin** (curl transport error, no origin
     response): a proxy/allowlist block. Raising the session network level CAN
     fix this.
   - **Origin HTTP 403 with the site's own headers**: target-side anti-bot or
     auth. Raising the network level will NOT fix this; use a real browser,
     operator-uploaded content, or an authenticated route.
   - **Permission wall**: reachable, authenticated, and still refused, because
     the *credential type* lacks the right. Authentication is not authorization.
     The canonical case: in a cloud session the GitHub MCP authenticates as the
     Claude GitHub App, and a GitHub App installation token cannot create a
     personal repository (`POST /user/repos` takes only a user OAuth token or a
     classic PAT with `repo` scope), so it returns 403 "Resource not accessible
     by integration" on a full network. Create personal repos from a local
     session, or create them under an org. No probe can predict this; read the
     capability's `remediation` field, and treat a probe result as proof of
     reachability only, never of authorization.

5. When a needed capability is unavailable, do not half-build. Say what is
   missing, quote the descriptor's `remediation` text from the JSON, and if the
   work cannot proceed here, offer a handoff brief (a committed doc + assets a
   capable session can pick up).

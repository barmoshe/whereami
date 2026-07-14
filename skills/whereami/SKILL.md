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

3. MCP auth verification (the detector only knows "configured", never "authenticated"):
   if MCP servers are configured and their auth status matters for the task,
   verify with a cheap read-only call per server, for example the GitHub MCP
   `get_me` or the Vercel MCP `list_teams`. Never call anything that creates,
   modifies, or deletes. After verifying, update the matching
   `"authenticated": "unverified"` field in `.whereami/state.json` to `"yes"` or
   `"no"` so other tooling can rely on it.

4. Interpreting a blocked fetch (the two 403s, do not conflate):
   - Transport blocked before the origin (curl transport error, no origin
     response): a proxy/allowlist block. Raising the session network level CAN
     fix this.
   - An origin HTTP 403 with the site's own headers: target-side anti-bot or
     auth. Raising the network level will NOT fix this; use a real browser,
     operator-uploaded content, or an authenticated route.

5. When a needed capability is unavailable, do not half-build. Say what is
   missing, quote the descriptor's `remediation` text from the JSON, and if the
   work cannot proceed here, offer a handoff brief (a committed doc + assets a
   capable session can pick up).

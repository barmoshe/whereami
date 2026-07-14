# whereami

Environment-aware Claude Code sessions.

At session start, `whereami` senses where the session is running (local, cloud,
CI, sandboxed) and what it can actually do (network lane, tools, MCP servers,
browser, disk), briefs Claude in a few lines, and saves the facts as JSON so
other hooks and scripts can branch on them. It is a neutral sensor first, with
an opt-in guidance layer on top.

Why: agents assume capabilities they do not have. A cloud session cannot fetch
an arbitrary website but can still deploy through an MCP server; a local session
can do both; a sandbox can do neither. `whereami` turns that from a mid-task
surprise (usually a confusing 403) into a fact Claude knows up front.

## Install

```
/plugin marketplace add barmoshe/whereami
/plugin install whereami@whereami
```

Then add `.whereami/` to your project's `.gitignore` (the state file is
per-machine, not for version control).

## What you get

- **SessionStart briefing**: a short block injected at session start, for example:

  ```
  [whereami] runtime=local os=macos network=full sandboxed=false
  MCP servers configured (auth unverified; ...): github vercel
  Available: vcs.git vcs.gh runtime.node browser.headless-chrome ...
  Unavailable: media.ffmpeg
  State: /path/to/project/.whereami/state.json
  ```

- **`.whereami/state.json`**: the same facts, structured, for tools and hooks.

- **The `whereami` skill**: ask Claude "where am I running" or "what can this
  session do" to re-check on demand. The skill can also verify MCP server
  authentication with read-only calls (the hook never does; a session-start
  subprocess cannot call MCP tools, and configuration does not prove auth).

## How detection works

Identity picks the lane, probes confirm ("detect, don't sniff"):

- **Runtime**: `CLAUDE_CODE_REMOTE` (cloud), `CI` / `GITHUB_ACTIONS` (ci),
  otherwise local; `CLAUDE_CODE_SANDBOXED` is reported separately.
- **Network**: two capped probes (2-3s) classify the lane: an allowlisted canary
  (`api.github.com`) proves any egress; a neutral host (`example.com`) separates
  `full` from `allowlist`; both silent means `none`.
- **The two 403s** (do not conflate): a transport-level block with no origin
  response is a proxy/allowlist 403, and raising the session network level can
  fix it. An origin HTTP 403 with the site's own headers is target-side
  (anti-bot or auth), and raising the network level will not fix it.
- **MCP servers**: parsed from `.mcp.json` and `~/.claude.json` as *configured*.
  MCP traffic routes through Anthropic's servers, so it bypasses any VM network
  allowlist: a session that cannot fetch a website may still create repos and
  deploy. Auth is verified only by the skill, via read-only calls.
- **Everything else is a Capability Descriptor** (see below). Tools, browser,
  disk are just bundled descriptors, not special cases.

The detector is a single POSIX sh script: no jq, no node, no bash-4 features.
It runs on macOS (bash 3.2 era), Linux, WSL, and Alpine. It always exits 0 and
degrades to `unknown` rather than failing a session, and the SessionStart hook
carries a 6 second timeout so a slow network can never stall startup.

## Capability Descriptors

Detection is declarative. A descriptor is a small text record (ssh_config
style), not code, so descriptors are safe to share:

```
Capability media.ffmpeg
  Description Audio/video encode, transcode, render
  Probe cmd ffmpeg
  Remediation Install ffmpeg, or hand off media rendering to an environment that has it.
  Risk low
  Environments local
```

- `Probe <primitive> <args>`: repeatable; if any probe passes, the capability is
  available. Primitives: `env NAME[=VALUE]`, `cmd BIN [BIN...]`,
  `file PATH [PATH...]` (globs allowed), `http URL`, `mcp NAME`, `disk MIN_MB`.
- `Requires`, `Remediation`, `Risk` (low / medium / high), `Environments`:
  recorded in the JSON so later tooling can act on them; v1 never executes a
  remediation.
- Bundled defaults live in the plugin's `probes.d/`. Add your own in
  `<project>/.whereami/probes.d/*.cap`; a project descriptor with the same
  `Capability` id overrides the bundled one.

## Configuration (optional, zero-config by default)

`whereami.config.json` at the project root:

```json
{
  "opinions": false,
  "canary_allowlisted": "https://api.github.com",
  "canary_neutral": "https://example.com",
  "extra_tools": ["terraform", "kubectl"]
}
```

- `opinions`: set `true` to enable the guidance layer (`guidance.d/*.tip`
  condition-to-tip rules, e.g. "restricted network: prefer the MCP lane"). Off
  by default; the sensor stays neutral.
- `extra_tools`: extra binaries to probe, without writing a descriptor.
- Keep the file flat JSON; the no-dependency parser reads only known keys.

## On-demand use

```
"$CLAUDE_PLUGIN_ROOT/scripts/whereami-detect.sh" --brief   # human/LLM briefing
"$CLAUDE_PLUGIN_ROOT/scripts/whereami-detect.sh" --json    # structured output
"$CLAUDE_PLUGIN_ROOT/scripts/whereami-detect.sh" --quiet   # just refresh state.json
"$CLAUDE_PLUGIN_ROOT/scripts/whereami-detect.sh" --no-net  # skip network probes
```

## Evidence and prior art

The design assembles mature patterns rather than inventing new ones: MAPE-K
(self-adaptive systems) for the sense-report-adapt shape, CI-detection
libraries (`ci-info`, `cucumber/ci-environment`) for "identify from a canonical
env signal, return structured metadata, share one detector", feature-detection
discipline from web development ("detect, don't sniff": probe the capability
you will use; keep identity env vars for known quirks), and Claude Code's own
sandbox startup probe and graceful degradation.

## License

MIT

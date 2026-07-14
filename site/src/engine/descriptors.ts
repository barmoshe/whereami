// The real bundled descriptor packs, verbatim from the plugin's probes.d/.
// Keeping them as source strings means the playground parses exactly what the
// shell detector parses, not a paraphrase of it.

export const NETWORK_CAP = `# Network reachability beyond the engine's built-in lane detection.

Capability net.live-fetch
  Description Fetch arbitrary live external websites (docs, brand sites, APIs not on an allowlist)
  Probe http https://example.com
  Requires network=full
  Remediation Raise the session network level to Full or Custom, ask the operator to upload the page content, or hand off to a local session.
  Risk medium
  Environments local

Capability net.github-api
  Description Reach the GitHub REST API directly (allowlisted in Claude Code cloud by default)
  Probe http https://api.github.com
  Remediation Usually open even on restricted networks; if blocked, use the GitHub MCP server instead (it routes through Anthropic and bypasses the VM allowlist).
  Risk low
  Environments local cloud ci
`

export const TOOLS_CAP = `Capability vcs.git
  Description Local git operations
  Probe cmd git
  Remediation Install git, or drive GitHub through the GitHub MCP server from a capable environment.
  Risk low
  Environments local cloud ci

Capability runtime.node
  Description Node.js runtime for JS/TS builds
  Probe cmd node
  Remediation Install Node.js (Claude Code ships as a native binary, so node is not guaranteed on the host).
  Risk low
  Environments local cloud ci

Capability media.ffmpeg
  Description Audio/video encode, transcode, render
  Probe cmd ffmpeg
  Remediation Install ffmpeg, or hand off media rendering to an environment that has it.
  Risk low
  Environments local
`

export const BROWSER_CAP = `Capability browser.headless-chrome
  Description Headless Chromium/Chrome for screenshots and live-site reads
  Probe cmd chromium chromium-browser google-chrome
  Probe file /Applications/Google*Chrome.app
  Remediation Install Chrome/Chromium, or use an operator-uploaded screenshot; sites behind anti-bot may need a real browser session either way.
  Risk low
  Environments local
`

export const MCP_CAP = `# MCP traffic routes through Anthropic's servers, so it bypasses any VM network
# allowlist. A session that cannot fetch a website may still create repos and deploy.
# The detector reports CONFIGURED only. The skill verifies auth with read-only calls.

Capability mcp.github
  Description GitHub MCP server configured (create repos, PRs, API without direct network)
  Probe mcp github
  Requires OAuth session on the Anthropic side
  Remediation Add the GitHub MCP server and authenticate it once from an interactive session.
  Risk low
  Environments local cloud

Capability mcp.vercel
  Description Vercel MCP server configured (deploys without direct network)
  Probe mcp vercel
  Requires OAuth session on the Anthropic side
  Remediation Add the Vercel MCP server / connector and authenticate it once from an interactive session.
  Risk low
  Environments local cloud
`

export const WORKSPACE_CAP = `Capability fs.disk-headroom
  Description At least 1GB of free disk at the project directory
  Probe disk 1024
  Remediation Clean build artifacts or delegate disk-heavy work to a roomier environment.
  Risk low
  Environments local cloud ci
`

export const BUNDLED_PACKS: { file: string; body: string }[] = [
  { file: '10-network.cap', body: NETWORK_CAP },
  { file: '20-tools.cap', body: TOOLS_CAP },
  { file: '30-browser.cap', body: BROWSER_CAP },
  { file: '40-mcp.cap', body: MCP_CAP },
  { file: '50-workspace.cap', body: WORKSPACE_CAP },
]

// The descriptor the playground opens with. Deliberately one the visitor can
// break and fix: it goes unavailable the moment you move to a restricted lane.
export const PLAYGROUND_SEED = `# Edit me. This is the real .cap format the detector parses.
# Probe lines OR together: any one passing makes the capability available.

Capability deploy.vercel
  Description Ship a production deploy
  Probe mcp vercel
  Probe cmd vercel
  Requires An authenticated Vercel session
  Remediation Add the Vercel MCP server, or install the Vercel CLI and log in.
  Risk low
  Environments local cloud

Capability brand.read-live-site
  Description Read a client's live site to match their brand
  Probe http https://example.com
  Requires network=full
  Remediation Ask the operator to upload the page, or hand off to a local session.
  Risk medium
  Environments local
`

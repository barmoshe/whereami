// A faithful TypeScript port of scripts/whereami-detect.sh.
//
// Same .cap grammar, same six probe primitives, same OR semantics across Probe
// lines, same lane classification, same briefing text. The only difference is
// that the real script asks the operating system and this one asks a simulated
// environment, so the site can show you an environment you are not currently in.

export type Runtime = 'local' | 'cloud' | 'ci'
export type NetworkLane = 'full' | 'allowlist' | 'none' | 'skipped' | 'unknown'
export type Status = 'available' | 'unavailable' | 'unknown'

/** The knobs the simulator exposes. Stands in for the real machine. */
export interface SimEnv {
  runtime: Runtime
  sandboxed: boolean
  network: NetworkLane
  /** MCP servers found in .mcp.json / ~/.claude.json (configured, not authenticated). */
  mcpConfigured: string[]
  /** Binaries on PATH. */
  tools: string[]
  /** Paths that exist (globs allowed, as in the shell `file` primitive). */
  files: string[]
  /** Free disk at the project dir, in MB. */
  diskFreeMb: number
  os: 'macos' | 'linux' | 'wsl'
}

export interface Capability {
  id: string
  description?: string
  probes: string[]
  requires?: string
  remediation?: string
  risk?: string
  environments?: string
  /** Which pack it came from, for the UI. */
  source?: string
}

export interface Evaluated extends Capability {
  status: Status
  detail: string
}

/* ------------------------------------------------------------------ parsing */

/** Parse the ssh_config-style .cap grammar. Unknown keys are ignored, as in sh. */
export function parseCaps(body: string, source?: string): Capability[] {
  const caps: Capability[] = []
  let cur: Capability | null = null

  for (const raw of body.split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue

    const sp = line.search(/\s/)
    const key = sp === -1 ? line : line.slice(0, sp)
    const val = sp === -1 ? '' : line.slice(sp).trim()

    switch (key) {
      case 'Capability': {
        // The shell strips anything outside [A-Za-z0-9._-]; match that.
        const id = val.replace(/[^A-Za-z0-9._-]/g, '')
        if (!id) break
        cur = { id, probes: [], source }
        caps.push(cur)
        break
      }
      case 'Description': if (cur) cur.description = val; break
      case 'Probe': if (cur && val) cur.probes.push(val); break
      case 'Requires': if (cur) cur.requires = val; break
      case 'Remediation': if (cur) cur.remediation = val; break
      case 'Risk': if (cur) cur.risk = val; break
      case 'Environments': if (cur) cur.environments = val; break
    }
  }
  return caps
}

/* --------------------------------------------------------------- primitives */

interface ProbeResult { status: Status; detail: string }

/** Shell-style glob match, so `/Applications/Google*Chrome.app` behaves. */
function globMatch(pattern: string, candidate: string): boolean {
  if (!pattern.includes('*')) return pattern === candidate
  const rx = new RegExp(
    '^' + pattern.split('*').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$',
  )
  return rx.test(candidate)
}

export function runProbe(probe: string, env: SimEnv): ProbeResult {
  const sp = probe.search(/\s/)
  const prim = sp === -1 ? probe : probe.slice(0, sp)
  const args = sp === -1 ? '' : probe.slice(sp).trim()

  switch (prim) {
    case 'env': {
      // The simulator models the identity vars the detector actually reads.
      const [name, want] = args.includes('=') ? args.split('=') : [args, undefined]
      const table: Record<string, string> = {
        CLAUDECODE: '1',
        CLAUDE_CODE_ENTRYPOINT: 'cli',
        ...(env.runtime === 'cloud' ? { CLAUDE_CODE_REMOTE: 'true' } : {}),
        ...(env.runtime === 'ci' ? { CI: 'true', GITHUB_ACTIONS: 'true' } : {}),
        ...(env.sandboxed ? { CLAUDE_CODE_SANDBOXED: '1' } : {}),
      }
      const v = table[name]
      if (want === undefined) {
        return v
          ? { status: 'available', detail: `${name}=${v}` }
          : { status: 'unavailable', detail: `${name} unset` }
      }
      return v === want
        ? { status: 'available', detail: `${name}=${v}` }
        : { status: 'unavailable', detail: `${name}=${v ?? 'unset'}` }
    }

    case 'cmd': {
      for (const bin of args.split(/\s+/)) {
        if (env.tools.includes(bin)) {
          return { status: 'available', detail: `/usr/bin/${bin}` }
        }
      }
      return { status: 'unavailable', detail: `none of: ${args}` }
    }

    case 'file': {
      for (const pat of args.split(/\s+/)) {
        if (env.files.some((f) => globMatch(pat, f))) {
          return { status: 'available', detail: pat }
        }
      }
      return { status: 'unavailable', detail: `missing: ${args}` }
    }

    case 'http': {
      if (env.network === 'skipped') {
        return { status: 'unknown', detail: 'network probes skipped' }
      }
      const host = args.replace(/^https?:\/\//, '').split('/')[0]
      // Allowlisted hosts stay reachable on a restricted lane; that asymmetry is
      // the whole point of the two-canary design.
      const allowlisted = host === 'api.github.com' || host.endsWith('.anthropic.com')

      if (env.network === 'full') return { status: 'available', detail: 'http 200' }
      if (env.network === 'allowlist') {
        return allowlisted
          ? { status: 'available', detail: 'http 200 (allowlisted host)' }
          : {
              status: 'unavailable',
              detail:
                'transport blocked before the origin (curl exit 35, code 000): proxy/allowlist block; raising the network level CAN fix this',
            }
      }
      if (env.network === 'none') {
        return {
          status: 'unavailable',
          detail:
            'transport blocked before the origin (curl exit 7, code 000): no egress; raising the network level CAN fix this',
        }
      }
      return { status: 'unknown', detail: 'no curl or wget' }
    }

    case 'mcp': {
      // Never "unavailable". A connector/harness-injected server is configured on
      // the Anthropic side and is invisible to a subprocess, so absent-from-config
      // is not absent-from-session. Reporting a hard no here is a false negative.
      return env.mcpConfigured.includes(args)
        ? {
            status: 'available',
            detail: 'configured (auth NOT verified; use the whereami skill to verify)',
          }
        : {
            status: 'unknown',
            detail:
              'not in .mcp.json or ~/.claude.json; a harness/connector-injected server is invisible to this subprocess, so this is NOT a no. Use the whereami skill to confirm with a read-only call.',
          }
    }

    case 'disk': {
      const min = Number(args)
      return env.diskFreeMb >= min
        ? { status: 'available', detail: `${env.diskFreeMb}MB free` }
        : { status: 'unavailable', detail: `${env.diskFreeMb}MB free < ${min}MB` }
    }

    default:
      return { status: 'unknown', detail: `unknown primitive: ${prim}` }
  }
}

/* ---------------------------------------------------------------- evaluation */

/** Any passing probe wins; otherwise keep the first definitive failure detail. */
export function evaluate(cap: Capability, env: SimEnv): Evaluated {
  if (cap.probes.length === 0) {
    return { ...cap, status: 'unknown', detail: 'no probe defined' }
  }
  let status: Status = 'unknown'
  let failDetail = ''

  for (const p of cap.probes) {
    const r = runProbe(p, env)
    if (r.status === 'available') return { ...cap, status: 'available', detail: r.detail }
    if (r.status === 'unavailable') {
      status = 'unavailable'
      if (!failDetail) failDetail = r.detail
    } else if (status !== 'unavailable') {
      status = 'unknown'
      if (!failDetail) failDetail = r.detail
    }
  }
  return { ...cap, status, detail: failDetail }
}

export function evaluateAll(caps: Capability[], env: SimEnv): Evaluated[] {
  // Later descriptors with the same id override earlier ones, as in the shell
  // (each parsed record overwrites $WORK/caps/<id>).
  const byId = new Map<string, Capability>()
  for (const c of caps) byId.set(c.id, c)
  return [...byId.values()].map((c) => evaluate(c, env)).sort((a, b) => a.id.localeCompare(b.id))
}

/* ------------------------------------------------------------------ briefing */

/** Byte-for-byte the shape of render_brief() in the shell script. */
export function renderBriefing(env: SimEnv, evaluated: Evaluated[]): string {
  const lines: string[] = []
  lines.push(
    `[whereami] runtime=${env.runtime} os=${env.os} network=${env.network} sandboxed=${env.sandboxed}`,
  )

  if (env.mcpConfigured.length) {
    lines.push(
      `MCP servers in config (auth unverified; MCP routes via Anthropic and bypasses any VM network allowlist): ${env.mcpConfigured.join(' ')}`,
    )
  } else {
    lines.push(
      'MCP servers in config: none. This is NOT "no MCP": connector/harness-injected servers are invisible to this probe. Check your actual tool list before concluding a server is missing.',
    )
  }

  const ids = (s: Status) =>
    evaluated.filter((c) => c.status === s).map((c) => c.id).join(' ')

  const avail = ids('available')
  const unavail = ids('unavailable')
  const unknown = ids('unknown')
  if (avail) lines.push(`Available: ${avail}`)
  if (unavail) lines.push(`Unavailable: ${unavail}`)
  if (unknown) lines.push(`Unknown: ${unknown}`)

  if (env.network === 'allowlist' || env.network === 'none') {
    lines.push(
      'Note: restricted network. A transport-level block (no origin response) is a proxy/allowlist block and CAN be fixed by raising the network level; an origin HTTP 403 is target-side and CANNOT. When blocked, emit a handoff brief instead of half-building.',
    )
  }
  lines.push(
    'Reachable is not authorized: these probes prove reachability only. A call can still 403 because the credential TYPE lacks the right (a GitHub App token cannot create a personal repo). Read a capability remediation before assuming it is missing.',
  )
  lines.push('State: /your/project/.whereami/state.json (re-check: run the whereami skill)')
  return lines.join('\n')
}

/** The .whereami/state.json a real run would write. */
export function renderState(env: SimEnv, evaluated: Evaluated[]) {
  return {
    whereami_version: '0.1.0',
    checked_at: '2026-07-14T00:00:00Z',
    facts: {
      runtime: env.runtime,
      sandboxed: env.sandboxed,
      entrypoint: 'cli',
      os: env.os,
      network: { lane: env.network },
      filesystem: {
        sibling_git_repos: env.runtime === 'cloud' ? 0 : 12,
        disk_free_mb: String(env.diskFreeMb),
      },
    },
    mcp_servers: env.mcpConfigured.map((name) => ({
      name,
      configured: true,
      authenticated: 'unverified',
    })),
    capabilities: evaluated.map((c) => ({
      id: c.id,
      status: c.status,
      detail: c.detail,
      ...(c.risk ? { risk: c.risk } : {}),
      ...(c.remediation ? { remediation: c.remediation } : {}),
    })),
  }
}

/* ------------------------------------------------------------------- presets */

export const PRESETS: Record<string, { label: string; blurb: string; env: SimEnv }> = {
  laptop: {
    label: 'Your laptop',
    blurb: 'Full network, every tool, sibling repos on disk. Everything works, so nothing teaches you anything.',
    env: {
      runtime: 'local',
      sandboxed: false,
      network: 'full',
      mcpConfigured: ['github', 'vercel'],
      tools: ['git', 'gh', 'node', 'python3', 'ffmpeg', 'chromium', 'docker', 'vercel'],
      files: ['/Applications/Google Chrome.app'],
      diskFreeMb: 240000,
      os: 'macos',
    },
  },
  cloud: {
    label: 'Cloud session',
    blurb: 'The one that started this. Ephemeral VM, allowlist-only egress, one repo. The front door is sealed, but MCP is a side door.',
    env: {
      runtime: 'cloud',
      sandboxed: true,
      network: 'allowlist',
      mcpConfigured: ['github', 'vercel'],
      tools: ['git', 'node', 'python3'],
      files: [],
      diskFreeMb: 28000,
      os: 'linux',
    },
  },
  ci: {
    label: 'CI runner',
    blurb: 'Full network, no browser, no MCP, no human to ask. Fails loud rather than degrade quietly.',
    env: {
      runtime: 'ci',
      sandboxed: false,
      network: 'full',
      mcpConfigured: [],
      tools: ['git', 'node', 'docker'],
      files: [],
      diskFreeMb: 14000,
      os: 'linux',
    },
  },
  locked: {
    label: 'Locked sandbox',
    blurb: 'No egress at all. Local files and nothing else. The honest answer is a handoff brief.',
    env: {
      runtime: 'cloud',
      sandboxed: true,
      network: 'none',
      mcpConfigured: [],
      tools: ['git'],
      files: [],
      diskFreeMb: 4000,
      os: 'linux',
    },
  },
}

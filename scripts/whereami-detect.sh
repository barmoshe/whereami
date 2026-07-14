#!/bin/sh
# whereami-detect.sh - sense where this Claude Code session runs and what it can do.
# POSIX sh. No jq, no node, no bash-4 features on the core path.
# Never breaks a session: always exits 0, degrades to "unknown" instead of failing.
#
# Usage:
#   whereami-detect.sh            # brief to stdout + write state.json (hook default)
#   whereami-detect.sh --brief    # same as default
#   whereami-detect.sh --json     # full JSON to stdout + write state.json
#   whereami-detect.sh --quiet    # write state.json only
#   whereami-detect.sh --no-net   # skip network probes (network=skipped)
#
# State file: ${CLAUDE_PROJECT_DIR:-.}/.whereami/state.json (gitignore .whereami/)
# Descriptors: <plugin>/probes.d/*.cap, then <project>/.whereami/probes.d/*.cap
#              (same Capability id: the later one wins).
# Config:      <project>/whereami.config.json (flat JSON, known keys only).

# --- never fail the session -------------------------------------------------
set +e
trap 'exit 0' INT TERM

VERSION="0.5.0"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE_DIR="$PROJECT_DIR/.whereami"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$PROJECT_DIR/whereami.config.json"

MODE="brief"
DO_NET=1
for arg in "$@"; do
  case "$arg" in
    --json) MODE="json" ;;
    --brief) MODE="brief" ;;
    --quiet) MODE="quiet" ;;
    --no-net) DO_NET=0 ;;
    --version) printf '%s\n' "$VERSION"; exit 0 ;;
  esac
done

# --- tiny helpers -------------------------------------------------------------
json_escape() {
  # stdin -> stdout: escape for a JSON string value; newlines become spaces.
  tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' \
    | sed 's/\\/\\\\/g; s/"/\\"/g'
}

je() { printf '%s' "$1" | json_escape; }

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown"; }

# config_get KEY -> value (flat JSON string/bool/number, heuristic; jq if present)
config_get() {
  [ -f "$CONFIG_FILE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r --arg k "$1" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$v" ] && printf '%s' "$v" && return 0
    return 1
  fi
  v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
  [ -n "$v" ] && printf '%s' "$v" | sed 's/[[:space:]]*$//' && return 0
  return 1
}

# config_get_list KEY -> newline-separated items from a flat JSON string array
config_get_list() {
  [ -f "$CONFIG_FILE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '(.[$k] // [])[]' "$CONFIG_FILE" 2>/dev/null
    return 0
  fi
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CONFIG_FILE" 2>/dev/null \
    | tr ',' '\n' | sed 's/[[:space:]"]*//g' | grep -v '^$'
}

# --- facts: identity (env vars pick the lane) ---------------------------------
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "${CLAUDE_CODE_REMOTE:-}" = "1" ]; then
  RUNTIME="cloud"
elif [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
  RUNTIME="ci"
else
  RUNTIME="local"
fi

case "${CLAUDE_CODE_SANDBOXED:-}" in
  ""|"false"|"0") SANDBOXED="false" ;;
  *) SANDBOXED="true" ;;
esac

ENTRYPOINT="${CLAUDE_CODE_ENTRYPOINT:-}"

OS_RAW=$(uname -s 2>/dev/null || echo unknown)
case "$OS_RAW" in
  Darwin) OS="macos" ;;
  Linux)
    if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
      OS="wsl"
    else
      OS="linux"
    fi ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *) OS="$(printf '%s' "$OS_RAW" | tr 'A-Z' 'a-z')" ;;
esac

# --- facts: network lane (two canaries, two 403s) ------------------------------
CANARY_ALLOWLISTED=$(config_get canary_allowlisted) || CANARY_ALLOWLISTED="https://api.github.com"
CANARY_NEUTRAL=$(config_get canary_neutral) || CANARY_NEUTRAL="https://example.com"

# probe_http URL -> "HTTPCODE|CURLEXIT" (000|127 when no prober available)
probe_http() {
  if command -v curl >/dev/null 2>&1; then
    _code=$(curl -sS -o /dev/null -m 3 --connect-timeout 2 -w '%{http_code}' "$1" 2>/dev/null)
    _rc=$?
    [ -n "$_code" ] || _code="000"
    printf '%s|%s' "$_code" "$_rc"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null -T 3 -t 1 "$1" 2>/dev/null
    _rc=$?
    if [ "$_rc" -eq 0 ]; then printf '200|0'; else printf '000|%s' "$_rc"; fi
  else
    printf '000|127'
  fi
}

# http_ok "CODE|EXIT" -> 0 if the origin answered at all (tunnel opened)
http_ok() {
  _c=${1%%|*}
  case "$_c" in
    2*|3*|4*|5*) return 0 ;;
    *) return 1 ;;
  esac
}

NETWORK="unknown"; NET_ALLOWLISTED=""; NET_NEUTRAL=""
if [ "$DO_NET" -eq 1 ]; then
  NET_ALLOWLISTED=$(probe_http "$CANARY_ALLOWLISTED")
  NET_NEUTRAL=$(probe_http "$CANARY_NEUTRAL")
  if [ "${NET_ALLOWLISTED#*|}" = "127" ]; then
    NETWORK="unknown"   # no curl and no wget on this host
  elif http_ok "$NET_NEUTRAL" && http_ok "$NET_ALLOWLISTED"; then
    NETWORK="full"
  elif http_ok "$NET_ALLOWLISTED"; then
    NETWORK="allowlist"
  elif http_ok "$NET_NEUTRAL"; then
    NETWORK="partial"   # odd but possible: neutral reachable, canary not
  else
    NETWORK="none"
  fi
else
  NETWORK="skipped"
fi

# --- facts: filesystem ----------------------------------------------------------
SIBLING_REPOS=0
for d in "$PROJECT_DIR"/../*/.git; do
  [ -e "$d" ] && SIBLING_REPOS=$((SIBLING_REPOS + 1))
done
# don't count the project itself
[ -e "$PROJECT_DIR/.git" ] && [ "$SIBLING_REPOS" -gt 0 ] && SIBLING_REPOS=$((SIBLING_REPOS - 1))

DISK_MB=$(df -m "$PROJECT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null)
case "$DISK_MB" in
  ''|*[!0-9]*) DISK_MB="unknown" ;;
esac

# --- facts: MCP servers configured (heuristic without jq, exact with jq) --------
mcp_names_from() {
  # $1 = json file; prints one server name per line
  [ -f "$1" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.mcpServers // {}) | keys[]' "$1" 2>/dev/null
    return 0
  fi
  # heuristic: names quoted immediately before a "{" after the mcpServers key
  sed -n '/"mcpServers"/,/^[[:space:]]*}/p' "$1" 2>/dev/null \
    | grep -o '"[A-Za-z0-9@._-]\{1,\}"[[:space:]]*:[[:space:]]*{' \
    | sed 's/^"//; s/"[[:space:]]*:[[:space:]]*{$//' \
    | grep -v '^mcpServers$'
}

MCP_CONFIGURED=$( { mcp_names_from "$PROJECT_DIR/.mcp.json"; mcp_names_from "$HOME/.claude.json"; } | sort -u | grep -v '^$')

# --- descriptor engine ----------------------------------------------------------
# .cap format (ssh_config style):
#   Capability <id>          starts a record
#     Description <text>
#     Probe <primitive> <args...>     (repeatable; ANY passing probe = available)
#     Requires <text>                 (recorded precondition, not enforced in v1)
#     Remediation <text>              (recorded; Stage 2 acts on it)
#     Risk low|medium|high            (risk tier of the remediation)
#     Environments <names...>         (recorded reachability metadata)
#
# Primitives:
#   env NAME[=VALUE]        env var set (or equal to VALUE)
#   cmd BIN [BIN...]        any of the binaries on PATH
#   file PATH [PATH...]     any path exists (~ expanded)
#   http URL                origin answers (2xx-5xx within 3s)
#   mcp NAME                MCP server NAME is configured
#   disk MIN_MB             at least MIN_MB free at the project dir

run_probe() {
  # $1 = full probe line; sets PROBE_STATUS + PROBE_DETAIL
  PROBE_STATUS="unknown"; PROBE_DETAIL=""
  _prim=${1%% *}; _args=${1#* }
  [ "$_args" = "$1" ] && _args=""
  case "$_prim" in
    env)
      # NEVER emit the value. An env var is where credentials live (GH_TOKEN,
      # API keys), and this detail string is printed by --json and written to
      # state.json. Report presence only. Learned the hard way: an earlier build
      # printed a live PAT straight into a session transcript.
      _name=${_args%%=*}
      if [ "$_name" = "$_args" ]; then
        eval "_v=\${$_name:-}"
        if [ -n "$_v" ]; then PROBE_STATUS="available"; PROBE_DETAIL="$_name is set (value not shown)"
        else PROBE_STATUS="unavailable"; PROBE_DETAIL="$_name unset"; fi
      else
        # Matching an expected value: the expectation is declared in the
        # descriptor (public), so echoing it back leaks nothing new. Still never
        # echo the actual value on mismatch.
        _want=${_args#*=}
        eval "_v=\${$_name:-}"
        if [ "$_v" = "$_want" ]; then PROBE_STATUS="available"; PROBE_DETAIL="$_name=$_want"
        else
          PROBE_STATUS="unavailable"
          if [ -n "$_v" ]; then PROBE_DETAIL="$_name is set but does not equal $_want"
          else PROBE_DETAIL="$_name unset"; fi
        fi
      fi ;;
    cmd)
      for _b in $_args; do
        if command -v "$_b" >/dev/null 2>&1; then
          PROBE_STATUS="available"; PROBE_DETAIL="$(command -v "$_b")"
          return 0
        fi
      done
      PROBE_STATUS="unavailable"; PROBE_DETAIL="none of: $_args" ;;
    file)
      for _p in $_args; do
        case "$_p" in "~"*) _p="$HOME${_p#\~}" ;; esac
        if [ -e "$_p" ]; then
          PROBE_STATUS="available"; PROBE_DETAIL="$_p"
          return 0
        fi
      done
      PROBE_STATUS="unavailable"; PROBE_DETAIL="missing: $_args" ;;
    http)
      if [ "$DO_NET" -eq 0 ]; then PROBE_STATUS="unknown"; PROBE_DETAIL="network probes skipped"; return 0; fi
      _r=$(probe_http "$_args")
      _code=${_r%%|*}; _rc=${_r#*|}
      if [ "$_rc" = "127" ]; then
        PROBE_STATUS="unknown"; PROBE_DETAIL="no curl or wget"
      elif http_ok "$_r"; then
        if [ "$_code" = "403" ]; then
          PROBE_STATUS="unavailable"; PROBE_DETAIL="origin 403 (target-side block: anti-bot or auth; raising the network level will NOT fix this)"
        else
          PROBE_STATUS="available"; PROBE_DETAIL="http $_code"
        fi
      else
        if [ "$_rc" != "0" ]; then
          PROBE_DETAIL="transport blocked before the origin (curl exit $_rc, code $_code): proxy/allowlist block; raising the network level CAN fix this"
        else
          PROBE_DETAIL="no origin response (code $_code)"
        fi
        PROBE_STATUS="unavailable"
      fi ;;
    mcp)
      # Two-tier, and deliberately never "unavailable".
      # A server can reach this session two ways: a config file (visible to us) or
      # harness/connector injection (NOT visible to a subprocess at all: connectors
      # are configured per session on the Anthropic side and their traffic routes
      # through Anthropic's servers, never through a file on disk).
      # So "absent from config" does NOT mean "absent from the session". Claiming
      # "unavailable" is a false negative, and it fired for real: a cloud session
      # reported mcp.github and mcp.vercel unavailable while both were live.
      # Report "unknown" and let the skill confirm with a read-only call.
      if printf '%s\n' "$MCP_CONFIGURED" | grep -qx "$_args" 2>/dev/null; then
        PROBE_STATUS="available"; PROBE_DETAIL="configured (auth NOT verified; use the whereami skill to verify)"
      else
        PROBE_STATUS="unknown"
        PROBE_DETAIL="not in .mcp.json or ~/.claude.json; a harness/connector-injected server is invisible to this subprocess, so this is NOT a no. Use the whereami skill to confirm with a read-only call."
      fi ;;
    disk)
      if [ "$DISK_MB" = "unknown" ]; then PROBE_STATUS="unknown"; PROBE_DETAIL="df unavailable"
      elif [ "$DISK_MB" -ge "$_args" ] 2>/dev/null; then PROBE_STATUS="available"; PROBE_DETAIL="${DISK_MB}MB free"
      else PROBE_STATUS="unavailable"; PROBE_DETAIL="${DISK_MB}MB free < ${_args}MB"; fi ;;
    *)
      PROBE_STATUS="unknown"; PROBE_DETAIL="unknown primitive: $_prim" ;;
  esac
}

# Working area for parsed descriptors (temp dir keeps precedence trivial:
# a later file for the same id overwrites the earlier one).
WORK=$(mktemp -d 2>/dev/null || echo "/tmp/whereami.$$")
mkdir -p "$WORK/caps"

parse_cap_file() {
  # $1 = .cap path; one record file per Capability id under $WORK/caps/<id>
  _id=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in \#*|"") continue ;; esac
    _key=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//; s/[[:space:]].*$//')
    _val=$(printf '%s' "$_line" | sed 's/^[[:space:]]*[A-Za-z]*[[:space:]]*//; s/[[:space:]]*$//')
    case "$_key" in
      Capability)
        _id=$(printf '%s' "$_val" | tr -cd 'A-Za-z0-9._-')
        [ -n "$_id" ] && : > "$WORK/caps/$_id" ;;
      Description|Probe|Unless|Blocked|Requires|Remediation|Risk|Environments)
        [ -n "$_id" ] && printf '%s\t%s\n' "$_key" "$_val" >> "$WORK/caps/$_id" ;;
    esac
  done < "$1"
}

for _f in "$PLUGIN_DIR"/probes.d/*.cap; do
  [ -f "$_f" ] && parse_cap_file "$_f"
done
for _f in "$PROJECT_DIR"/.whereami/probes.d/*.cap; do
  [ -f "$_f" ] && parse_cap_file "$_f"
done

# Extra tools from config become synthetic descriptors.
config_get_list extra_tools | while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  _tid="tool.$_t"
  { printf 'Description\tExtra tool from whereami.config.json\n'
    printf 'Probe\tcmd %s\n' "$_t"
    printf 'Risk\tlow\n'; } > "$WORK/caps/$_tid"
done

# Evaluate all descriptors.
CAPS_JSON=""
AVAILABLE_IDS=""; UNAVAILABLE_IDS=""; UNKNOWN_IDS=""
for _capfile in "$WORK/caps"/*; do
  [ -f "$_capfile" ] || continue
  _cid=$(basename "$_capfile")
  _desc=""; _req=""; _rem=""; _risk=""; _envs=""; _blocked=""
  _status="unknown"; _detail="no probe defined"
  _had_probe=0
  while IFS='	' read -r _k _v; do
    case "$_k" in
      Description) _desc="$_v" ;;
      Requires) _req="$_v" ;;
      Remediation) _rem="$_v" ;;
      Risk) _risk="$_v" ;;
      Environments) _envs="$_v" ;;
      Blocked) _blocked="$_v" ;;
    esac
  done < "$_capfile"
  # probes: any pass wins; first definitive failure detail kept otherwise
  _fail_detail=""
  while IFS='	' read -r _k _v; do
    [ "$_k" = "Probe" ] || continue
    _had_probe=1
    run_probe "$_v"
    if [ "$PROBE_STATUS" = "available" ]; then
      _status="available"; _detail="$PROBE_DETAIL"
      break
    elif [ "$PROBE_STATUS" = "unavailable" ]; then
      _status="unavailable"
      [ -n "$_fail_detail" ] || _fail_detail="$PROBE_DETAIL"
    elif [ "$_status" != "unavailable" ]; then
      _status="unknown"; _fail_detail="${_fail_detail:-$PROBE_DETAIL}"
    fi
  done < "$_capfile"
  [ "$_status" = "available" ] || _detail="$_fail_detail"
  [ "$_had_probe" -eq 0 ] && _status="unknown"

  # Unless = a POLICY VETO. If any Unless probe matches, the capability is
  # unavailable no matter what the Probe lines found.
  # This exists because "I hold the right credential" is not the same as "the
  # environment will let me use it". A Claude Code cloud session can hold a valid
  # user PAT and still be refused: its egress proxy filters GitHub API *paths* to
  # the session's bound repo, so POST /user/repos is denied at the proxy, never
  # reaching GitHub. Probing the credential alone reports a confident, wrong yes.
  while IFS='	' read -r _k _v; do
    [ "$_k" = "Unless" ] || continue
    run_probe "$_v"
    if [ "$PROBE_STATUS" = "available" ]; then
      _status="unavailable"
      _detail="${_blocked:-blocked by environment policy ($_v)}"
      break
    fi
  done < "$_capfile"

  _entry=$(printf '{"id":"%s","status":"%s","detail":"%s"' "$(je "$_cid")" "$_status" "$(je "$_detail")")
  [ -n "$_desc" ] && _entry="$_entry,\"description\":\"$(je "$_desc")\""
  [ -n "$_req" ] && _entry="$_entry,\"requires\":\"$(je "$_req")\""
  [ -n "$_rem" ] && _entry="$_entry,\"remediation\":\"$(je "$_rem")\""
  [ -n "$_risk" ] && _entry="$_entry,\"risk\":\"$(je "$_risk")\""
  [ -n "$_envs" ] && _entry="$_entry,\"environments\":\"$(je "$_envs")\""
  _entry="$_entry}"
  if [ -n "$CAPS_JSON" ]; then CAPS_JSON="$CAPS_JSON,$_entry"; else CAPS_JSON="$_entry"; fi
  case "$_status" in
    available) AVAILABLE_IDS="$AVAILABLE_IDS $_cid" ;;
    unavailable) UNAVAILABLE_IDS="$UNAVAILABLE_IDS $_cid" ;;
    *) UNKNOWN_IDS="$UNKNOWN_IDS $_cid" ;;
  esac
done

# --- guidance (opt-in, off by default) -------------------------------------------
# .tip format:  Tip <id> / When <fact>=<value> / Say <text>
tip_matches() {
  # "$1" like "network=allowlist" or "runtime=cloud" (single condition, v1)
  [ -n "$1" ] || return 0
  _f=${1%%=*}; _want=${1#*=}
  case "$_f" in
    network) [ "$NETWORK" = "$_want" ] ;;
    runtime) [ "$RUNTIME" = "$_want" ] ;;
    sandboxed) [ "$SANDBOXED" = "$_want" ] ;;
    os) [ "$OS" = "$_want" ] ;;
    *) return 1 ;;
  esac
}

append_tip() {
  _t=$(printf '{"id":"%s","when":"%s","tip":"%s"}' "$(je "$1")" "$(je "$2")" "$(je "$3")")
  if [ -n "$TIPS_JSON" ]; then TIPS_JSON="$TIPS_JSON,$_t"; else TIPS_JSON="$_t"; fi
}

OPINIONS=$(config_get opinions) || OPINIONS="false"
TIPS_JSON=""
if [ "$OPINIONS" = "true" ]; then
  for _tf in "$PLUGIN_DIR"/guidance.d/*.tip "$PROJECT_DIR"/.whereami/guidance.d/*.tip; do
    [ -f "$_tf" ] || continue
    _tid=""; _when=""; _say=""
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in \#*|"") continue ;; esac
      _key=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//; s/[[:space:]].*$//')
      _val=$(printf '%s' "$_line" | sed 's/^[[:space:]]*[A-Za-z]*[[:space:]]*//; s/[[:space:]]*$//')
      case "$_key" in
        Tip) # flush previous record
          if [ -n "$_tid" ] && [ -n "$_say" ] && tip_matches "$_when"; then append_tip "$_tid" "$_when" "$_say"; fi
          _tid="$_val"; _when=""; _say="" ;;
        When) _when="$_val" ;;
        Say) _say="$_val" ;;
      esac
    done < "$_tf"
    if [ -n "$_tid" ] && [ -n "$_say" ] && tip_matches "$_when"; then append_tip "$_tid" "$_when" "$_say"; fi
  done
fi

# --- assemble JSON -----------------------------------------------------------------
MCP_JSON=""
for _m in $MCP_CONFIGURED; do
  _e=$(printf '{"name":"%s","configured":true,"authenticated":"unverified"}' "$(je "$_m")")
  if [ -n "$MCP_JSON" ]; then MCP_JSON="$MCP_JSON,$_e"; else MCP_JSON="$_e"; fi
done

NET_DETAIL_JSON=$(printf '"canary_allowlisted":{"url":"%s","result":"%s"},"canary_neutral":{"url":"%s","result":"%s"}' \
  "$(je "$CANARY_ALLOWLISTED")" "$(je "$NET_ALLOWLISTED")" \
  "$(je "$CANARY_NEUTRAL")" "$(je "$NET_NEUTRAL")")

STATE_JSON=$(printf '{
"whereami_version":"%s",
"checked_at":"%s",
"facts":{
"runtime":"%s",
"sandboxed":%s,
"entrypoint":"%s",
"os":"%s",
"network":{"lane":"%s",%s},
"filesystem":{"sibling_git_repos":%s,"disk_free_mb":"%s"},
"project_dir":"%s"
},
"mcp_servers":[%s],
"capabilities":[%s],
"guidance":[%s]
}' \
  "$VERSION" "$(now_utc)" "$RUNTIME" "$SANDBOXED" "$(je "$ENTRYPOINT")" "$OS" \
  "$NETWORK" "$NET_DETAIL_JSON" "$SIBLING_REPOS" "$DISK_MB" "$(je "$PROJECT_DIR")" \
  "$MCP_JSON" "$CAPS_JSON" "$TIPS_JSON")

# --- write state -------------------------------------------------------------------
mkdir -p "$STATE_DIR" 2>/dev/null
printf '%s\n' "$STATE_JSON" > "$STATE_FILE" 2>/dev/null

# --- render brief ------------------------------------------------------------------
render_brief() {
  printf '[whereami] runtime=%s os=%s network=%s sandboxed=%s\n' "$RUNTIME" "$OS" "$NETWORK" "$SANDBOXED"
  if [ -n "$MCP_CONFIGURED" ]; then
    printf 'MCP servers in config (auth unverified; MCP routes via Anthropic and bypasses any VM network allowlist): %s\n' \
      "$(printf '%s' "$MCP_CONFIGURED" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  else
    printf 'MCP servers in config: none. This is NOT "no MCP": connector/harness-injected servers are invisible to this probe. Check your actual tool list before concluding a server is missing.\n'
  fi
  [ -n "$AVAILABLE_IDS" ] && printf 'Available:%s\n' "$AVAILABLE_IDS"
  [ -n "$UNAVAILABLE_IDS" ] && printf 'Unavailable:%s\n' "$UNAVAILABLE_IDS"
  [ -n "$UNKNOWN_IDS" ] && printf 'Unknown:%s\n' "$UNKNOWN_IDS"
  if [ "$NETWORK" = "allowlist" ] || [ "$NETWORK" = "none" ]; then
    printf 'Note: restricted network. A transport-level block (no origin response) is a proxy/allowlist block and CAN be fixed by raising the network level; an origin HTTP 403 is target-side and CANNOT. When blocked, emit a handoff brief instead of half-building.\n'
  fi
  printf 'Reachable is not authorized: these probes prove reachability only. A call can still 403 because the credential TYPE lacks the right (a GitHub App token cannot create a personal repo). Read a capability remediation before assuming it is missing.\n'
  printf 'State: %s (re-check: run the whereami skill)\n' "$STATE_FILE"
  if [ "$OPINIONS" = "true" ] && [ -n "$TIPS_JSON" ]; then
    printf 'Guidance is ON; see "guidance" in state.json.\n'
  fi
}

case "$MODE" in
  json) printf '%s\n' "$STATE_JSON" ;;
  brief) render_brief ;;
  quiet) : ;;
esac

rm -rf "$WORK" 2>/dev/null
exit 0

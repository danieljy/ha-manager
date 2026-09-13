#!/usr/bin/env bash
# bin/_common.sh — shared plumbing for the ha-* scripts. Source it; don't run it.
#
#   . "$(dirname "$0")/_common.sh"
#   ha_parse_args "$@"       # -i/--instance, -y/--yes → HA_INSTANCE_FLAG, HA_YES, HA_ARGS
#   ha_resolve_instance      # loads instances/<name>.env, prints the target to stderr
#   ha_guard "what"          # refuse on a protected instance unless --yes was given
#   ha_request GET /api/...  # body → file $HA_RESPONSE, status → $HA_HTTP_STATUS
#
# Written for macOS /bin/bash 3.2: no associative arrays, no ${var,,}, no mapfile.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "_common.sh is meant to be sourced by the ha-* scripts, not run." >&2
  exit 64
fi

HA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HA_INSTANCES_DIR="$HA_ROOT/instances"
HA_INSTANCE_DOTFILE="$HA_ROOT/.ha-instance"
HA_TEMPLATE_NAME="example"

# The only keys read from an instance file. Anything else is ignored with a
# warning, so a stray line can't smuggle in e.g. HA_YES=1.
HA_ENV_KEYS="HA_LABEL HA_URL HA_TOKEN HA_SSH_HOST HA_MOUNT HA_INSTALL_TYPE HA_PROTECTED"

# State owned by this file.
HA_ARGS=()
HA_YES=0
HA_INSTANCE_FLAG=""
HA_INSTANCE_NAME=""
HA_INSTANCE_FILE=""
HA_INSTANCE_SOURCE=""
HA_HTTP_STATUS=""
HA_RESPONSE=""
HA_TMPDIR=""
HA_LABEL="" HA_URL="" HA_TOKEN="" HA_SSH_HOST="" HA_MOUNT="" HA_INSTALL_TYPE="" HA_PROTECTED=""

# ---------------------------------------------------------------------------
# Output helpers. Everything informational goes to stderr so stdout stays
# clean for JSON and piping.
# ---------------------------------------------------------------------------
ha_log()  { printf '[ha] %s\n' "$*" >&2; }
ha_warn() { printf '[ha] warning: %s\n' "$*" >&2; }
ha_die()  { printf '[ha] error: %s\n' "$*" >&2; exit 1; }
ha_have() { command -v "$1" >/dev/null 2>&1; }

ha_ensure_tmpdir() {
  [ -n "$HA_TMPDIR" ] && return 0
  HA_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ha-manager.XXXXXX")"
  trap 'rm -rf "$HA_TMPDIR"' EXIT
}

# ---------------------------------------------------------------------------
# Instance listing: one name per line (instances/*.env minus the template).
# ---------------------------------------------------------------------------
ha_list_instances() {
  local f name
  for f in "$HA_INSTANCES_DIR"/*.env; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .env)"
    [ "$name" = "$HA_TEMPLATE_NAME" ] && continue
    printf '%s\n' "$name"
  done
}

ha_print_instance_list() {
  local names
  names="$(ha_list_instances)"
  if [ -n "$names" ]; then
    printf '[ha] configured instances:\n' >&2
    printf '[ha]   %s\n' $names >&2
  else
    printf '[ha] no instances configured — copy instances/example.env to instances/<name>.env\n' >&2
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing. Pulls out the flags every script shares and leaves the
# rest in HA_ARGS:
#   -i NAME | --instance NAME | --instance=NAME   select the instance
#   -y | --yes                                    override the protection guard
#   --                                            end of common flags
# With HA_PARSE_STOP_AT_POSITIONAL=1 parsing stops at the first non-flag word
# and everything after it passes through untouched — ha-ssh needs that so
# `ha-ssh -i prox grep -i foo file` doesn't eat "-i foo".
# ---------------------------------------------------------------------------
ha_parse_args() {
  HA_ARGS=()
  HA_YES=0
  HA_INSTANCE_FLAG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--instance)
        [ $# -ge 2 ] || ha_die "$1 requires an instance name"
        HA_INSTANCE_FLAG="$2"; shift 2 ;;
      --instance=*) HA_INSTANCE_FLAG="${1#--instance=}"; shift ;;
      -y|--yes)     HA_YES=1; shift ;;
      --)           shift; break ;;
      *)
        if [ "${HA_PARSE_STOP_AT_POSITIONAL:-0}" = 1 ]; then break; fi
        HA_ARGS+=("$1"); shift ;;
    esac
  done
  while [ $# -gt 0 ]; do HA_ARGS+=("$1"); shift; done
}

# ---------------------------------------------------------------------------
# Instance file loading. Parses KEY="value" lines; deliberately does NOT
# source the file, so it can't execute anything and only known keys land.
# ---------------------------------------------------------------------------
ha_load_instance_file() {
  local file="$1" line key val ok k n=0
  HA_LABEL="" HA_URL="" HA_TOKEN="" HA_SSH_HOST="" HA_MOUNT="" HA_INSTALL_TYPE="" HA_PROTECTED=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"                # ltrim
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    line="${line#export }"
    case "$line" in
      *=*) ;;
      *) ha_warn "$file:$n: ignoring line without '='"; continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"                   # rtrim key
    val="${val#"${val%%[![:space:]]*}"}"                   # ltrim value
    val="${val%"${val##*[![:space:]]}"}"                   # rtrim value
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    ok=0
    for k in $HA_ENV_KEYS; do [ "$k" = "$key" ] && ok=1; done
    if [ "$ok" = 1 ]; then
      printf -v "$key" '%s' "$val"
    else
      ha_warn "$file:$n: ignoring unknown key '$key'"
    fi
  done < "$file"
  HA_URL="${HA_URL%/}"
  case "$HA_MOUNT" in "~/"*) HA_MOUNT="$HOME/${HA_MOUNT#\~/}" ;; esac
}

# Warn if the instance file (which holds a token) is readable by others.
ha_check_instance_file_perms() {
  local file="$1" mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
  case "$mode" in
    ""|*00) ;;
    *) ha_warn "$file is readable by other users (mode $mode); run: chmod 600 $file" ;;
  esac
}

# ---------------------------------------------------------------------------
# Instance resolution: -i/--instance flag, then $HA_INSTANCE, then the
# .ha-instance dotfile at the repo root. There is no default on purpose.
# Sets HA_INSTANCE_NAME / HA_INSTANCE_FILE / HA_INSTANCE_SOURCE plus the HA_*
# config variables, and prints the target to stderr.
# ---------------------------------------------------------------------------
ha_resolve_instance() {
  local name="" source="" file tag=""

  if [ -n "$HA_INSTANCE_FLAG" ]; then
    name="$HA_INSTANCE_FLAG"; source="--instance"
  elif [ -n "${HA_INSTANCE:-}" ]; then
    name="$HA_INSTANCE"; source="\$HA_INSTANCE"
  elif [ -f "$HA_INSTANCE_DOTFILE" ]; then
    name="$(head -n1 "$HA_INSTANCE_DOTFILE" | tr -d '[:space:]')"
    source=".ha-instance"
  fi

  if [ -z "$name" ]; then
    printf '[ha] error: no instance selected, and there is no default.\n' >&2
    printf '[ha] pick one with -i NAME / --instance NAME, HA_INSTANCE=NAME, or a .ha-instance file.\n' >&2
    ha_print_instance_list
    exit 2
  fi

  case "$name" in
    */*|.*|"$HA_TEMPLATE_NAME") ha_die "invalid instance name '$name'" ;;
  esac

  file="$HA_INSTANCES_DIR/$name.env"
  if [ ! -f "$file" ]; then
    printf '[ha] error: no instance file for "%s" (expected %s)\n' "$name" "$file" >&2
    ha_print_instance_list
    exit 2
  fi

  ha_check_instance_file_perms "$file"
  ha_load_instance_file "$file"

  HA_INSTANCE_NAME="$name"
  HA_INSTANCE_FILE="$file"
  HA_INSTANCE_SOURCE="$source"

  if ha_is_protected; then tag=" [PROTECTED]"; fi
  ha_log "instance: $name — ${HA_LABEL:-no label} — ${HA_URL:-no url}$tag  (via $source)"
}

ha_require_token() {
  [ -n "$HA_TOKEN" ] || ha_die "HA_TOKEN is empty in $HA_INSTANCE_FILE"
}

# ---------------------------------------------------------------------------
# Protection guard.
# ---------------------------------------------------------------------------
ha_is_protected() {
  case "$(printf '%s' "$HA_PROTECTED" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# ha_guard "description of the operation"
# Blocks state-changing operations on a protected instance unless --yes.
ha_guard() {
  local what="${1:-this operation}"
  if ha_is_protected; then
    if [ "$HA_YES" != 1 ]; then
      printf '[ha] BLOCKED: instance "%s" is protected; refusing: %s\n' "$HA_INSTANCE_NAME" "$what" >&2
      printf '[ha] re-run with --yes to override. That is a human decision — do not automate it.\n' >&2
      exit 3
    fi
    ha_log "--yes given: proceeding with '$what' on PROTECTED instance $HA_INSTANCE_NAME"
  fi
}

# ---------------------------------------------------------------------------
# HTTP. ha_request METHOD PATH [BODY]
#   Response body is written to the file named by $HA_RESPONSE, the HTTP
#   status to $HA_HTTP_STATUS ("000" if nothing answered). Returns curl's
#   exit status: 0 for any HTTP response, non-zero if the request never
#   completed (unreachable, timeout, DNS).
#   Everything, including the bearer token, goes to curl through a private
#   config file in a mode-700 temp dir — never on a command line, never in
#   `ps`, never on stderr.
# ---------------------------------------------------------------------------
ha_api_path() {
  case "$1" in
    /api|/api/*) printf '%s' "$1" ;;
    api|api/*)   printf '/%s' "$1" ;;
    /*)          printf '/api%s' "$1" ;;
    *)           printf '/api/%s' "$1" ;;
  esac
}

ha_request() {
  local method="$1" path="$2" body="${3:-}" cfg out bodyfile rc had_e
  [ -n "$HA_URL" ] || ha_die "HA_URL is empty in $HA_INSTANCE_FILE"
  path="$(ha_api_path "$path")"
  ha_ensure_tmpdir
  cfg="$HA_TMPDIR/curlrc"
  out="$HA_TMPDIR/response"
  bodyfile="$HA_TMPDIR/body"
  rm -f "$out"
  {
    printf 'silent\nshow-error\n'
    printf 'connect-timeout = %s\n' "${HA_CONNECT_TIMEOUT:-5}"
    printf 'max-time = %s\n' "${HA_MAX_TIME:-60}"
    printf 'request = "%s"\n' "$method"
    printf 'header = "Content-Type: application/json"\n'
    if [ -n "$HA_TOKEN" ]; then
      printf 'header = "Authorization: Bearer %s"\n' "$HA_TOKEN"
    fi
    if [ -n "$body" ]; then
      printf '%s' "$body" > "$bodyfile"
      printf 'data-binary = "@%s"\n' "$bodyfile"
    fi
    printf 'output = "%s"\n' "$out"
    printf 'write-out = "%%{http_code}"\n'
    printf 'url = "%s%s"\n' "$HA_URL" "$path"
  } > "$cfg"

  # Run curl with errexit off, then restore whatever the caller had.
  case $- in *e*) had_e=1 ;; *) had_e=0 ;; esac
  set +e
  HA_HTTP_STATUS="$(curl -K "$cfg")"
  rc=$?
  if [ "$had_e" = 1 ]; then set -e; fi
  rm -f "$cfg" "$bodyfile"
  [ -f "$out" ] || : > "$out"
  HA_RESPONSE="$out"
  return $rc
}

# Print a response file: pretty JSON via jq when available and the body
# parses, otherwise verbatim (with a trailing newline added if missing).
ha_print_response() {
  local file="$1" raw="${2:-0}"
  if [ "$raw" = 0 ] && ha_have jq && jq empty "$file" 2>/dev/null; then
    jq . "$file"
  else
    cat "$file"
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then echo; fi
  fi
}

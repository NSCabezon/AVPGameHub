# Sourced (not run) by build_run_vpro.sh, build_run_slink_vpro.sh, visionos/run.sh and
# visionos/stage_alyx.sh. Part of AVP Game Hub, not upstream Klepton.
#
# Loads <repo>/local/config.env — KEY=VALUE lines, `#` comments, optional `export ` — and
# exports every key the environment has not already set (the environment always wins).
# KL_LOCAL_CONFIG names another file. See local/config.env.example at the repo root.
_kl_cfg_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KL_LOCAL_CONFIG="${KL_LOCAL_CONFIG:-$_kl_cfg_root/local/config.env}"
if [ -f "$KL_LOCAL_CONFIG" ]; then
  while IFS= read -r _kl_line || [ -n "$_kl_line" ]; do
    _kl_line="${_kl_line#"${_kl_line%%[![:space:]]*}"}"
    case "$_kl_line" in ''|'#'*) continue ;; esac
    _kl_line="${_kl_line#export }"
    _kl_key="${_kl_line%%=*}"
    [ "$_kl_key" != "$_kl_line" ] || continue
    _kl_val="${_kl_line#*=}"
    _kl_val="${_kl_val%\"}"; _kl_val="${_kl_val#\"}"; _kl_val="${_kl_val%\'}"; _kl_val="${_kl_val#\'}"
    case "$_kl_key" in *[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
    if [ -z "${!_kl_key:-}" ]; then export "$_kl_key=$_kl_val"; fi
  done < "$KL_LOCAL_CONFIG"
fi
unset _kl_cfg_root _kl_line _kl_key _kl_val

# A device build needs an App ID your team can register. targets.py's hub row carries a
# placeholder (com.example.avpgamehub) that only the Simulator accepts.
kl_require_bundle_id() {
  case "${1:-}" in
    ''|com.example.*)
      echo "!! bundle id is '${1:-}' — set KLEPTON_BUNDLE_ID in local/config.env" >&2
      echo "!!   (copy local/config.env.example; use an id under your own reverse domain," >&2
      echo "!!   e.g. com.yourname.avpgamehub, and keep it: the game data lives in its container)" >&2
      exit 1 ;;
  esac
}

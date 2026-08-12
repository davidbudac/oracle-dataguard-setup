# ============================================================
# Shared helpers for the observer SYS -> SYSDG conversion kit.
# Sourced by the numbered scripts in this directory.
#
# Deliberately standalone: no dependency on common/dg_functions.sh,
# the NFS share, or standby_config_*.env, so this folder can be
# copied on its own to any primary / observer host.
# ============================================================

# Colors (respect NO_COLOR and non-TTY stdout)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_INFO=$(printf '\033[0;32m'); C_WARN=$(printf '\033[0;33m')
    C_ERR=$(printf '\033[0;31m');  C_OFF=$(printf '\033[0m')
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log_info()  { printf '%s[INFO]%s  %s\n' "$C_INFO" "$C_OFF" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

log_section() {
    printf '\n============================================================\n'
    printf '%s\n' "$*"
    printf '============================================================\n'
}

# prompt_password VAR "Prompt text" -> sets VAR (never echoed).
# Interactive only: these scripts never accept passwords via argv or env.
prompt_password() {
    local __var="$1" __prompt="$2" __val=""
    [[ -t 0 ]] || die "A password prompt is required (${__prompt}) but stdin is not a terminal. Run interactively."
    printf '%s: ' "$__prompt" >&2
    IFS= read -rs __val
    printf '\n' >&2
    printf -v "$__var" '%s' "$__val"
}

# prompt_with_default VAR "Prompt text" "default"
# Non-TTY stdin takes the default silently.
prompt_with_default() {
    local __var="$1" __prompt="$2" __def="$3" __val=""
    if [[ -t 0 ]]; then
        printf '%s [%s]: ' "$__prompt" "$__def" >&2
        IFS= read -r __val
    fi
    [[ -n "$__val" ]] || __val="$__def"
    printf -v "$__var" '%s' "$__val"
}

# confirm_proceed "Question?" -> 0 yes / 1 no. Non-TTY: no (safe default).
confirm_proceed() {
    local ans=""
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive stdin: answering NO to: $1"
        return 1
    fi
    printf '%s [y/N]: ' "$1" >&2
    IFS= read -r ans
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

check_oracle_env() {
    [[ -n "${ORACLE_HOME:-}" ]] || die "ORACLE_HOME is not set."
    [[ -x "$ORACLE_HOME/bin/sqlplus" || -x "$ORACLE_HOME/bin/dgmgrl" ]] \
        || die "Neither sqlplus nor dgmgrl found under $ORACLE_HOME/bin - is ORACLE_HOME correct?"
}

# run_sql "sql" -> stdout. Connects '/ as sysdba' to the local instance.
# The heredoc is unquoted so callers must escape dollar signs in view
# names (v\$database) when building the SQL in double quotes.
run_sql() {
    "$ORACLE_HOME/bin/sqlplus" -s -L / as sysdba <<EOF
set pagesize 0 feedback off verify off heading off echo off trimspool on linesize 400
whenever sqlerror exit 1
$1
exit
EOF
}

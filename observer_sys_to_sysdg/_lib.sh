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
# SET DEFINE OFF comes first: callers embed passwords in the SQL, and with
# substitution on an '&' in a password is read as a substitution variable.
run_sql() {
    "$ORACLE_HOME/bin/sqlplus" -s -L / as sysdba <<EOF
set define off
set pagesize 0 feedback off verify off heading off echo off trimspool on linesize 400 tab off
whenever sqlerror exit 1
$1
exit
EOF
}

# dgmgrl_output_has_error "<output>" -> 0 when the output looks like a failure.
# dgmgrl -silent exits 0 even when the command failed, so the text is the only
# signal. Anchored like migrate_noncdb_to_pdb/_lib.sh (kept standalone, so a
# manual copy): ORA-/DGM- codes (ignoring "Warning:" lines, which carry
# ORA- codes for non-failures), a nonzero "Error: N" line - "Error: 0" is the
# benign per-member status in SHOW CONFIGURATION - and a standalone "Failed.".
dgmgrl_output_has_error() {
    local output="$1"
    if printf '%s\n' "$output" | grep -Ev '^[[:space:]]*Warning:' | grep -Eq 'ORA-[0-9]|DGM-[0-9]'; then
        return 0
    fi
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Error:[[:space:]]*[1-9]'; then
        return 0
    fi
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Failed\.[[:space:]]*$'; then
        return 0
    fi
    return 1
}

# wallet_credential_lines -> stdin: mkstore -listCredential output;
# stdout: one "alias user" pair per credential ("1: prim SYS" -> "prim SYS").
wallet_credential_lines() {
    tr -d '\r' | sed -n 's/^[0-9][0-9]*:[[:space:]]*\([^[:space:]][^[:space:]]*\)[[:space:]][[:space:]]*\([^[:space:]][^[:space:]]*\)[[:space:]]*$/\1 \2/p'
}

# sqlnet_wallet_dir FILE -> directory of the WALLET_LOCATION entry, or empty.
# Case-insensitive, anchored to WALLET_LOCATION: a plain substring match would
# also hit ENCRYPTION_WALLET_LOCATION (a TDE keystore, NOT a credential wallet).
sqlnet_wallet_dir() {
    awk '
        toupper($0) ~ /^[[:space:]]*WALLET_LOCATION/ { grab = 1 }
        grab { block = block " " $0 }
        END {
            if (match(toupper(block), /DIRECTORY[[:space:]]*=[[:space:]]*[^)[:space:]]+/)) {
                s = substr(block, RSTART, RLENGTH)
                sub(/^[Dd][Ii][Rr][Ee][Cc][Tt][Oo][Rr][Yy][[:space:]]*=[[:space:]]*/, "", s)
                print s
            }
        }' "$1"
}

# canonical_dir DIR -> physical path when DIR exists, else DIR minus any
# trailing slash. For comparing two spellings of the same wallet directory.
canonical_dir() {
    local d="$1" c=""
    c=$(cd "$d" 2>/dev/null && pwd -P) || c=""
    if [[ -z "$c" ]]; then
        c=$(printf '%s' "$d" | sed 's|/*$||')
    fi
    printf '%s' "$c"
}

# broker_member_names -> stdin: SHOW CONFIGURATION output; stdout: the
# member DB_UNIQUE_NAMEs, one per line (the "name - Primary database" lines
# of the Members: block).
broker_member_names() {
    tr -d '\r' | awk '
        $1 == "Members:" { m = 1; next }
        m && NF == 0     { m = 0 }
        m && $2 == "-"   { print $1 }'
}

# broker_property_value "<SHOW DATABASE VERBOSE output>" PropertyName -> value
broker_property_value() {
    printf '%s\n' "$1" | tr -d '\r' \
        | grep -i "^[[:space:]]*${2}[[:space:]]*=" | head -1 \
        | sed -e "s/^[^=]*=[[:space:]]*//" -e "s/'//g" -e "s/[[:space:]]*\$//"
}

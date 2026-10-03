#!/usr/bin/env bash
# ============================================================
# Oracle Data Guard Setup - Step 5: Clone Standby Database
# ============================================================
# Run this script on the STANDBY database server.
# It performs RMAN duplicate to create the standby database.
#
# RMAN tuning flags:
#   -c, --channels NUM   Number of parallel channels (default: 1). Allocated on
#                        BOTH sides (NUM target + NUM auxiliary, see below)
#   -r, --rate RATE      Per-channel throughput limit: integer with optional
#                        K/M/G suffix (e.g. 200M, 1G). Default: unlimited
#
# Example: bash ./standby/05_clone_standby.sh -c 4 -r 200M
#
# Inherited FRA (Traditional mode): DUPLICATE ... SPFILE copies the primary's
# spfile and overrides only the SET list. With USE_FRA_FOR_STANDBY=NO the
# standby must have NO Fast Recovery Area, so when the LIVE primary has
# db_recovery_file_dest set, the RMAN body adds
#   RESET DB_RECOVERY_FILE_DEST / RESET DB_RECOVERY_FILE_DEST_SIZE
# (otherwise the primary's FRA path and size would be handed to the standby,
# and a directory missing on this host can fail the auxiliary restart inside
# the non-restartable DUPLICATE). The live primary is queried before anything
# is changed (a failed query refuses the step); after the DUPLICATE the
# standby's effective values are read back and compared with the choice.
# -n/--check reports from the config's recorded primary FRA and stops before
# any write (the live query needs the SYS password, which -n never asks for).
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
# RMAN tuning flags parsed below (-c/--channels and -r/--rate take a value)
DG_SCRIPT_FLAGS='-c= --channels= -r= --rate='
enable_verbose_mode "$@"

# ============================================================
# Parse RMAN tuning flags
# ============================================================

RMAN_CHANNELS=1
RMAN_RATE=""

# Mirrors DG_SCRIPT_FLAGS above: enable_verbose_mode already rejected unknown
# options, so this loop only extracts the two valued flags (both the
# "--channels 4" and "--channels=4" spellings).
_args=("$@")
_i=0
RMAN_CHANNELS_SET=0
RMAN_RATE_SET=0
while [[ $_i -lt ${#_args[@]} ]]; do
    case "${_args[$_i]}" in
        -c|--channels)
            _i=$((_i + 1))
            RMAN_CHANNELS="${_args[$_i]:-}"
            RMAN_CHANNELS_SET=1
            ;;
        --channels=*)
            RMAN_CHANNELS="${_args[$_i]#--channels=}"
            RMAN_CHANNELS_SET=1
            ;;
        -r|--rate)
            _i=$((_i + 1))
            RMAN_RATE="${_args[$_i]:-}"
            RMAN_RATE_SET=1
            ;;
        --rate=*)
            RMAN_RATE="${_args[$_i]#--rate=}"
            RMAN_RATE_SET=1
            ;;
    esac
    _i=$((_i + 1))
done

if ! [[ "$RMAN_CHANNELS" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid --channels value: '$RMAN_CHANNELS' (must be a positive integer)"
    exit 1
fi

# The rate is pasted into the RMAN script (ALLOCATE ... RATE <value>), so it
# must be RMAN's "integer [K|M|G]" form and nothing else. An empty value
# after -r/--rate would otherwise silently mean "unlimited".
if [[ "$RMAN_RATE_SET" == "1" ]] && ! [[ "$RMAN_RATE" =~ ^[1-9][0-9]*[KkMmGg]?$ ]]; then
    log_error "Invalid --rate value: '$RMAN_RATE' (use a positive integer with optional K, M or G suffix, e.g. 200M)"
    exit 1
fi

# ============================================================
# Main Script
# ============================================================

print_banner "Step 5: Clone Standby Database"
init_progress 9

# Initialize logging (will reinitialize with DB name later)
init_log "05_clone_standby"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_nfs_mount || exit 1

# Check for standby config files - support unique naming
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "05_clone_standby_${STANDBY_DB_UNIQUE_NAME}"

# Verify we're on the standby host (same check as step 3). This step starts,
# and may SHUTDOWN ABORT, an instance addressed only by ORACLE_SID, so running
# it on the wrong host would act on whatever that SID is there.
CURRENT_HOST=$(hostname 2>/dev/null)
if ! hostnames_match "$CURRENT_HOST" "$STANDBY_HOSTNAME"; then
    log_warn "Current hostname ($CURRENT_HOST) does not match expected standby hostname ($STANDBY_HOSTNAME)"
    if ! confirm_proceed_or_check "Continue anyway?"; then
        exit 1
    fi
fi

# Verify one standby db_create_online_log_dest_<n> value: shell/RMAN-safe,
# and (unless it is an ASM '+' value) an existing, writable directory on
# THIS host. RMAN DUPLICATE is not restartable, so a missing directory has
# to be caught here rather than as ORA-19504/ORA-27040 mid-duplicate.
# Usage: check_standby_online_log_dest_dir <n> <dir>
check_standby_online_log_dest_dir() {
    local _n="$1" _dir="$2"
    if ! is_safe_omf_dest_path "$_dir"; then
        log_error "db_create_online_log_dest_${_n} value '${_dir}' is not a safe absolute path or +DISKGROUP"
        log_error "  (letters, digits and _ . / + - only) - fix STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n} in ${STANDBY_CONFIG_FILE}"
        return 1
    fi
    [[ "$_dir" == +* ]] && return 0
    if [[ ! -d "$_dir" ]]; then
        log_error "db_create_online_log_dest_${_n} directory does not exist on this host: ${_dir}"
        log_error "  Create it (mkdir -p ${_dir}, owned by the Oracle user), or edit"
        log_error "  STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n} in ${STANDBY_CONFIG_FILE} and re-run step 3"
        return 1
    fi
    if [[ ! -w "$_dir" ]]; then
        log_error "db_create_online_log_dest_${_n} directory is not writable by $(id -un 2>/dev/null || echo this user): ${_dir}"
        log_error "  Fix the ownership/permissions, or edit STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n}"
        log_error "  in ${STANDBY_CONFIG_FILE} and re-run step 3"
        return 1
    fi
    return 0
}

# ---- begin fra reset helpers ----
# Pure helpers (no database, no logging) for the inherited-FRA handling:
# RMAN DUPLICATE ... SPFILE copies the primary's spfile, so a primary with
# db_recovery_file_dest set hands it (and its size) to a standby that was
# configured WITHOUT an FRA unless the SPFILE clause RESETs both. Kept between
# the markers, function headers and closing braces at column 0, so
# tests/test_step5_fra_reset.sh can extract and source them without running
# this script.

# Trim whitespace and trailing slashes ("/" itself is kept) for comparing paths.
# Usage: fra_normalize_path <path>
fra_normalize_path() {
    local _p="$1"
    _p=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    while [[ "$_p" == */ && "$_p" != "/" ]]; do
        _p="${_p%/}"
    done
    printf '%s' "$_p"
}

# A path as it may be echoed into logs: verbatim when it passes
# is_safe_omf_dest_path, otherwise a placeholder (never an unvalidated value).
# Usage: fra_display_path <path>
fra_display_path() {
    if is_safe_omf_dest_path "$1"; then
        printf '%s' "$1"
    else
        printf '%s' "(path with unusual characters - not shown)"
    fi
}

# Parse the live-primary FRA query output ("name|value" rows plus the
# trailing "fra_query_ok|1" sentinel that proves the query really ran - an
# empty result alone is a valid "no FRA"). Sets:
#   PRIMARY_FRA_QUERY_OK       YES when the sentinel row was seen, else NO
#   PRIMARY_FRA_DEST           db_recovery_file_dest ("" when unset)
#   PRIMARY_FRA_SIZE           db_recovery_file_dest_size ("" when unset)
#   PRIMARY_FRA_ARCHIVE_DESTS  space-separated log_archive_dest_<n> names
#                              (n>1) whose value uses USE_DB_RECOVERY_FILE_DEST
# Usage: parse_primary_fra_params "<raw query output>"
parse_primary_fra_params() {
    local _raw="$1" _pname _pval
    PRIMARY_FRA_QUERY_OK="NO"
    PRIMARY_FRA_DEST=""
    PRIMARY_FRA_SIZE=""
    PRIMARY_FRA_ARCHIVE_DESTS=""
    while IFS='|' read -r _pname _pval; do
        _pname=$(printf '%s' "$_pname" | tr -d '\r[:space:]')
        _pval=$(printf '%s' "$_pval" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$_pname" in
            fra_query_ok) PRIMARY_FRA_QUERY_OK="YES" ;;
            db_recovery_file_dest) PRIMARY_FRA_DEST="$_pval" ;;
            db_recovery_file_dest_size) PRIMARY_FRA_SIZE="$_pval" ;;
            log_archive_dest_1) ;;
            log_archive_dest_[0-9]|log_archive_dest_[0-9][0-9])
                PRIMARY_FRA_ARCHIVE_DESTS="${PRIMARY_FRA_ARCHIVE_DESTS}${PRIMARY_FRA_ARCHIVE_DESTS:+ }${_pname}"
                ;;
        esac
    done <<EOF
$_raw
EOF
    return 0
}

# The FRA-related lines of the SPFILE clause (one per line, 4-space indent,
# no trailing newline), Traditional mode only (OMF prints nothing: its RMAN
# body carries its own FRA SET lines):
#   USE_FRA_FOR_STANDBY=YES                  -> the two SET lines
#   no FRA for the standby, primary has one  -> RESET both (no value text)
#   no FRA for the standby, primary has none -> nothing (nothing to inherit;
#                                               RESET of an absent parameter
#                                               is deliberately not emitted)
# Usage: build_rman_fra_lines <STORAGE_MODE> <USE_FRA_FOR_STANDBY> <standby_fra> <standby_fra_size> <primary_fra_dest>
build_rman_fra_lines() {
    local _mode="$1" _use_fra="$2" _sfra="$3" _ssize="$4" _pfra="$5"
    [[ "$_mode" == "OMF" ]] && return 0
    if [[ "$_use_fra" == "YES" ]]; then
        printf "    SET DB_RECOVERY_FILE_DEST='%s'\n    SET DB_RECOVERY_FILE_DEST_SIZE='%s'" "$_sfra" "$_ssize"
    elif [[ -n "$_pfra" ]]; then
        printf '    RESET DB_RECOVERY_FILE_DEST\n    RESET DB_RECOVERY_FILE_DEST_SIZE'
    fi
    return 0
}

# Without an FRA the explicit LOG_ARCHIVE_DEST_1 SET must be a real directory:
# an empty STANDBY_ARCHIVE_DEST would produce "LOCATION= ..." and one that
# resolves to USE_DB_RECOVERY_FILE_DEST would need the FRA that was just reset.
# Prints the reason and returns 1 on a problem; always 0 for OMF / FRA=YES.
# Usage: check_archive_dest_1_without_fra <STORAGE_MODE> <USE_FRA_FOR_STANDBY> <standby_archive_dest>
check_archive_dest_1_without_fra() {
    local _mode="$1" _use_fra="$2" _dest="$3" _up
    [[ "$_mode" == "OMF" || "$_use_fra" == "YES" ]] && return 0
    if [[ -z "$(printf '%s' "$_dest" | tr -d '[:space:]')" ]]; then
        printf '%s' "USE_FRA_FOR_STANDBY is not YES but STANDBY_ARCHIVE_DEST is empty - log_archive_dest_1 would have no location"
        return 1
    fi
    _up=$(printf '%s' "$_dest" | tr '[:lower:]' '[:upper:]')
    case "$_up" in
        *USE_DB_RECOVERY_FILE_DEST*)
            printf '%s' "STANDBY_ARCHIVE_DEST resolves to USE_DB_RECOVERY_FILE_DEST but the standby is configured without an FRA"
            return 1
            ;;
    esac
    return 0
}

# Compare the standby's effective FRA parameters (read back after the
# DUPLICATE) with the choice. Prints one message; return 0 = as chosen,
# 1 = contradicts the choice (fail the step), 2 = acceptable but worth a
# warning (FRA disabled, dest empty, but a non-zero size was left behind -
# V$PARAMETER reports an unset size as 0).
#   expect_fra=NO  -> dest must be empty
#   expect_fra=YES -> dest must equal the configured path (whitespace and
#                     trailing slashes ignored)
# Usage: fra_readback_verdict <YES|NO> <expected_path> <actual_dest> <actual_size>
fra_readback_verdict() {
    local _expect="$1" _want _got _size
    _want=$(fra_normalize_path "$2")
    _got=$(fra_normalize_path "$3")
    _size=$(printf '%s' "$4" | tr -d '[:space:]')
    if [[ "$_expect" == "YES" ]]; then
        if [[ -n "$_want" && "$_got" == "$_want" ]]; then
            printf '%s' "db_recovery_file_dest is ${_got} as configured (size ${_size:-unset})"
            return 0
        fi
        printf '%s' "db_recovery_file_dest is '${_got}' but the configuration says '${_want}'"
        return 1
    fi
    if [[ -n "$_got" ]]; then
        printf '%s' "the standby still has db_recovery_file_dest='${_got}' although it is configured without an FRA"
        return 1
    fi
    if [[ -n "$_size" && "$_size" != "0" ]]; then
        printf '%s' "db_recovery_file_dest is empty as chosen, but db_recovery_file_dest_size=${_size} was left behind (harmless without a destination)"
        return 2
    fi
    printf '%s' "db_recovery_file_dest is empty as chosen (no FRA on the standby)"
    return 0
}
# ---- end fra reset helpers ----

# Set Oracle environment. Prefer a locally-set ORACLE_HOME when it points
# at a usable installation (bin/sqlplus present) - the standby host's
# Oracle installation may live somewhere other than the path recorded in
# the config. Fall back to STANDBY_ORACLE_HOME from the config otherwise
# (same preference as 03_setup_standby_env.sh; check_oracle_env below
# still validates the final value).
if [[ -n "$ORACLE_HOME" && -x "$ORACLE_HOME/bin/sqlplus" ]]; then
    if [[ -n "$STANDBY_ORACLE_HOME" && "$ORACLE_HOME" != "$STANDBY_ORACLE_HOME" ]]; then
        log_warn "Locally-set ORACLE_HOME ($ORACLE_HOME) differs from config STANDBY_ORACLE_HOME ($STANDBY_ORACLE_HOME)"
        log_warn "Using the locally-set ORACLE_HOME"
    fi
    export ORACLE_HOME
else
    export ORACLE_HOME="$STANDBY_ORACLE_HOME"
fi
export ORACLE_SID="$STANDBY_ORACLE_SID"
export PATH="$ORACLE_HOME/bin:$PATH"

check_oracle_env || exit 1

# Check pfile exists
PFILE="${ORACLE_HOME}/dbs/init${ORACLE_SID}.ora"
if [[ ! -f "$PFILE" ]]; then
    log_error "Parameter file not found: $PFILE"
    log_error "Please run 03_setup_standby_env.sh first"
    exit 1
fi

# Check password file exists
PWD_FILE="${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
if [[ ! -f "$PWD_FILE" ]]; then
    log_error "Password file not found: $PWD_FILE"
    log_error "Please run 03_setup_standby_env.sh first"
    exit 1
fi

# ============================================================
# Verify Listener Status
# ============================================================

progress_step "Verifying Listener"

log_info "Checking listener status..."
if ! "$ORACLE_HOME/bin/lsnrctl" status > /dev/null 2>&1; then
    log_error "Listener is not running"
    log_error "Please start the listener: lsnrctl start"
    exit 1
fi

# Check for static registration. Match the service line itself, not any
# mention of the name: the bare name also occurs in <name>_DGMGRL, host names
# and paths. Case-insensitive; an optional ".domain" suffix is allowed.
_svc_name_re=$(printf '%s' "$STANDBY_DB_UNIQUE_NAME" | sed 's/[.]/\\./g')
if ! "$ORACLE_HOME/bin/lsnrctl" status 2>&1 | grep -qiE "^[[:space:]]*Service \"${_svc_name_re}(\.[^\" ]*)?\" has"; then
    log_error "Static registration not found for $STANDBY_DB_UNIQUE_NAME"
    log_error "Please verify listener.ora configuration"
    exit 1
fi

log_info "Listener is running with static registration"

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

print_list_block "This Step Will Change" \
    "After you type the confirmation, shut down any leftover standby instance for ${STANDBY_ORACLE_SID} (refused if it is not a PHYSICAL STANDBY) and restart it in NOMOUNT." \
    "Run RMAN DUPLICATE FROM ACTIVE DATABASE against ${PRIMARY_TNS_ALIAS} -> ${STANDBY_TNS_ALIAS}." \
    "Verify the SPFILE built by RMAN and start managed recovery."

print_list_block "This Step Will Not Change" \
    "It will not create the broker configuration." \
    "It will not modify the primary host files." \
    "It will not remove old standby files for you if a reset is required."

print_list_block "Files and Commands" \
    "PFILE: ${PFILE}" \
    "Password file: ${PWD_FILE}" \
    "RMAN cmdfile: local private temp dir (mode 600, holds SYS connect strings, deleted after run)" \
    "RMAN log: ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.log"

print_status_block "RMAN Tuning" \
    "Channels (target + auxiliary, each)" "$RMAN_CHANNELS" \
    "Per-channel rate" "${RMAN_RATE:-unlimited}"

print_list_block "Recovery If This Step Fails" \
    "This step is not directly restartable once RMAN duplicate starts." \
    "To reset: shut down the standby instance, remove standby datafiles/controlfiles/redo logs, then re-run this step." \
    "Review the RMAN log first to confirm whether cleanup is actually required."

record_next_step "./primary/06_configure_broker.sh"

# OMF: local-only check of the online log destinations the config already
# names (no SYS password needed). The authoritative check against the live
# primary runs after the password prompt below; this one lets -n report
# the problems it can see without it.
if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    _olog_local_bad=0
    _n=1
    while [[ $_n -le 5 ]]; do
        eval "_olog_dir=\${STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n}:-}"
        if [[ -n "$_olog_dir" ]]; then
            if check_standby_online_log_dest_dir "$_n" "$_olog_dir"; then
                log_info "db_create_online_log_dest_${_n}: ${_olog_dir} (OK)"
            else
                _olog_local_bad=1
            fi
        fi
        _n=$((_n + 1))
    done
    if [[ $_olog_local_bad -ne 0 ]]; then
        exit 1
    fi
fi

# Traditional mode without a standby FRA: the standby must not inherit the
# primary's. Local checks only here (no SYS password in -n); the live primary
# query that decides the RESET lines runs after the password prompt below.
if [[ "$STANDBY_STORAGE_MODE" != "OMF" && "$USE_FRA_FOR_STANDBY" != "YES" ]]; then
    if ! _ad1_msg=$(check_archive_dest_1_without_fra "$STANDBY_STORAGE_MODE" "$USE_FRA_FOR_STANDBY" "${STANDBY_ARCHIVE_DEST:-}"); then
        log_error "$_ad1_msg"
        log_error "Fix STANDBY_ARCHIVE_DEST in ${STANDBY_CONFIG_FILE} and run 02_generate_standby_config.sh --regenerate"
        exit 1
    fi
    if [[ -n "${DB_RECOVERY_FILE_DEST:-}" ]]; then
        log_info "Config records a primary FRA ($(fra_display_path "$DB_RECOVERY_FILE_DEST")) and USE_FRA_FOR_STANDBY=NO:"
        log_info "  the RMAN SPFILE clause will RESET DB_RECOVERY_FILE_DEST and DB_RECOVERY_FILE_DEST_SIZE so the standby has no FRA"
        log_info "  (confirmed against the live primary after the SYS password prompt; the live value decides)"
    else
        log_info "Config records no primary FRA and USE_FRA_FOR_STANDBY=NO: no FRA reset expected (re-checked against the live primary)"
    fi
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Standby clone preflight complete. No instance or RMAN changes were applied."
fi

# ============================================================
# Test TNS Connectivity
# ============================================================

progress_step "Testing Network Connectivity"

# Test tnsping to primary
log_info "Testing tnsping to primary ($PRIMARY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$PRIMARY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach primary database via tnsping"
    log_error "Please verify tnsnames.ora and network connectivity"
    exit 1
fi
log_info "tnsping to primary successful"

# Test tnsping to self (standby)
log_info "Testing tnsping to standby ($STANDBY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach standby via tnsping"
    log_error "Please verify listener and tnsnames.ora"
    exit 1
fi
log_info "tnsping to standby successful"

# ============================================================
# Prompt for SYS Password
# ============================================================

progress_step "Authenticating to Primary"

echo ""
# Everything from the prompt to the end of verification reads or holds the
# SYS password: keep xtrace (-v) off so it is never printed (C2). The calls
# nest, so verify_sys_password/prompt_password pausing again inside is fine.
pause_verbose_trace
SYS_PASSWORD=$(prompt_password "Enter SYS password for primary database")

# L16: verify_sys_password() and the RMAN CONNECT lines below both embed
# this in sys/"<pw>"@... - an embedded double-quote breaks that syntax and
# would otherwise be misreported as a plain "Invalid SYS password".
if [[ "$SYS_PASSWORD" == *'"'* ]]; then
    log_error "SYS password must not contain a double-quote (\") character"
    exit 1
fi

# Verify password against primary
log_info "Verifying SYS password against primary..."
if ! verify_sys_password "$SYS_PASSWORD" "$PRIMARY_TNS_ALIAS"; then
    # verify_sys_password() only reports pass/fail, but leaves the sqlplus
    # output (never the password) in VERIFY_SYS_ERROR_TEXT. Inspect that to
    # distinguish a locked SYS account (ORA-28000) from a plain bad password
    # or connectivity failure and point the operator at the right fix. Do NOT
    # connect a second time to fetch the error: every extra failed logon
    # counts toward FAILED_LOGIN_ATTEMPTS and locks SYS sooner.
    resume_verbose_trace
    if echo "$VERIFY_SYS_ERROR_TEXT" | grep -q "ORA-28000"; then
        log_error "SYS account on the primary is LOCKED (ORA-28000)"
        log_error ""
        log_error "To proceed with this clone, temporarily unlock and reset SYS on the PRIMARY:"
        log_error "  sqlplus / as sysdba"
        log_error "  ALTER USER SYS ACCOUNT UNLOCK;"
        log_error "  ALTER USER SYS IDENTIFIED BY <temporary_password>;"
        log_error ""
        log_error "After this clone completes, re-apply your site's SYS lockdown policy and make sure"
        log_error "the standby's password file matches the primary's."
    else
        log_error "Invalid SYS password or cannot connect to primary"
    fi
    exit 1
fi
resume_verbose_trace
log_info "Password verified successfully"

# ============================================================
# OMF: Inherited File-Placement Preflight (authoritative)
# ============================================================
# RMAN DUPLICATE ... SPFILE copies the primary's spfile and overrides only
# what the SET clauses name. Ask the LIVE primary (it may have changed since
# step 1) for the parameters that would otherwise steer file placement:
#   - log_file_name_convert / db_file_name_convert set -> refuse (they
#     outrank the OMF parameters in RMAN's naming precedence)
#   - db_create_online_log_dest_1..5 set -> each needs a standby directory
#     (from the config, else step 2's default) that exists and is writable
#     here, and gets an explicit SET in the RMAN body below.
# Runs BEFORE the SHUTDOWN ABORT / STARTUP NOMOUNT below: nothing has been
# changed yet, so every failure here is free. A failed query also stops the
# step - this run cannot be repeated, so it must not go in blind.
RESOLVED_OLOG_DEST_1=""
RESOLVED_OLOG_DEST_2=""
RESOLVED_OLOG_DEST_3=""
RESOLVED_OLOG_DEST_4=""
RESOLVED_OLOG_DEST_5=""
OMF_ONLINE_LOG_DEST_SETS=""
if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    log_section "Checking Primary File-Placement Parameters (OMF)"

    # CONNECT fed on stdin (never argv) with DEFINE OFF, as in
    # verify_sys_password(); xtrace is paused so the password is not traced.
    pause_verbose_trace
    _omf_rc=0
    OMF_PRIMARY_PARAMS_RAW=$(sqlplus -s /nolog <<SQL 2>&1
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${SYS_PASSWORD}"@${PRIMARY_TNS_ALIAS} AS SYSDBA
@${SQL_DIR}/queries/get_omf_placement_params.sql
SQL
) || _omf_rc=$?
    resume_verbose_trace

    if [[ $_omf_rc -ne 0 ]]; then
        log_error "Could not read db_create_online_log_dest_n / *_file_name_convert from the primary (sqlplus exit ${_omf_rc})"
        log_error "  $(_first_ora_line "$OMF_PRIMARY_PARAMS_RAW")"
        log_error "Refusing to start the non-restartable RMAN duplicate without this check. Nothing has been changed."
        exit 1
    fi

    parse_omf_placement_params "$OMF_PRIMARY_PARAMS_RAW"

    if [[ "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET" == "YES" || "$OMF_PARAM_DB_FILE_NAME_CONVERT_SET" == "YES" ]]; then
        log_omf_inherited_convert_error "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET" "$OMF_PARAM_DB_FILE_NAME_CONVERT_SET"
        log_error "Nothing has been changed on this host."
        exit 1
    fi

    _olog_bad=0
    _n=1
    while [[ $_n -le 5 ]]; do
        eval "_olog_pri=\$OMF_PARAM_ONLINE_LOG_DEST_${_n}"
        eval "_olog_cfg=\${STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n}:-}"
        if [[ -n "$_olog_pri" ]]; then
            _olog_stby="$_olog_cfg"
            if [[ -z "$_olog_stby" ]]; then
                _olog_stby=$(omf_default_online_log_dest "$_n" "$STANDBY_DB_CREATE_FILE_DEST" "$STANDBY_DB_RECOVERY_FILE_DEST")
                log_warn "Primary sets db_create_online_log_dest_${_n} (${_olog_pri}) but the config has no STANDBY_DB_CREATE_ONLINE_LOG_DEST_${_n}"
                log_warn "  (older config, or the primary gained it after step 2) - using the default: ${_olog_stby}"
            fi
            if check_standby_online_log_dest_dir "$_n" "$_olog_stby"; then
                eval "RESOLVED_OLOG_DEST_${_n}=\$_olog_stby"
                log_info "db_create_online_log_dest_${_n}: primary ${_olog_pri} -> standby ${_olog_stby}"
            else
                _olog_bad=1
            fi
        elif [[ -n "$_olog_cfg" ]]; then
            log_info "db_create_online_log_dest_${_n}: not set on the primary any more - config value ${_olog_cfg} ignored"
        fi
        _n=$((_n + 1))
    done
    if [[ $_olog_bad -ne 0 ]]; then
        log_error "Fix the directory problem(s) above, then re-run this step. Nothing has been changed."
        exit 1
    fi

    _omf_sets=$(build_rman_online_log_dest_set_lines "$RESOLVED_OLOG_DEST_1" "$RESOLVED_OLOG_DEST_2" "$RESOLVED_OLOG_DEST_3" "$RESOLVED_OLOG_DEST_4" "$RESOLVED_OLOG_DEST_5") || {
        log_error "Internal error: could not build the db_create_online_log_dest_n SET clauses"
        exit 1
    }
    if [[ -n "$_omf_sets" ]]; then
        OMF_ONLINE_LOG_DEST_SETS="
${_omf_sets}"
    else
        log_info "Primary sets no db_create_online_log_dest_n and no *_file_name_convert - nothing inherited to override"
    fi
fi

# ============================================================
# Traditional Mode Without a Standby FRA: Inherited FRA Preflight
# ============================================================
# Same inheritance problem as the OMF placement parameters above: DUPLICATE
# copies the primary's spfile, so a primary with db_recovery_file_dest set
# would hand that path and size to a standby configured WITHOUT an FRA - and a
# directory missing here can fail the auxiliary restart inside the
# non-restartable DUPLICATE. Ask the LIVE primary (it may have changed since
# step 1; the config's recorded value is only a cross-check) and let the RMAN
# body RESET both parameters when it has an FRA. Emitting RESET for a
# parameter the source spfile does not contain is not lab-verified, so the
# lines are produced only when the primary really has one. Runs BEFORE the
# SHUTDOWN ABORT / STARTUP NOMOUNT: nothing has been changed, so a failed
# query is a refusal, not a pass.
LIVE_PRIMARY_FRA_DEST=""
if [[ "$STANDBY_STORAGE_MODE" != "OMF" && "$USE_FRA_FOR_STANDBY" != "YES" ]]; then
    log_section "Checking Primary Fast Recovery Area (standby has none)"

    # Same connection mechanism as the OMF preflight: CONNECT on stdin (never
    # argv), DEFINE OFF, xtrace paused. The inline SQL stays here (not in
    # sql/queries) so this fix touches one file; V\$ is escaped for the
    # unquoted here-document. The trailing fra_query_ok row proves the query
    # ran: an empty result alone just means "no FRA".
    pause_verbose_trace
    _fra_rc=0
    FRA_PRIMARY_PARAMS_RAW=$(sqlplus -s /nolog <<SQL 2>&1
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${SYS_PASSWORD}"@${PRIMARY_TNS_ALIAS} AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT name || '|' || value FROM V\$PARAMETER
WHERE name IN ('db_recovery_file_dest', 'db_recovery_file_dest_size')
AND value IS NOT NULL
UNION ALL
SELECT name || '|' || value FROM V\$PARAMETER
WHERE REGEXP_LIKE(name, '^log_archive_dest_[0-9]+\$')
AND UPPER(value) LIKE '%USE_DB_RECOVERY_FILE_DEST%'
UNION ALL
SELECT 'fra_query_ok|1' FROM dual;
EXIT;
SQL
) || _fra_rc=$?
    resume_verbose_trace

    if [[ $_fra_rc -ne 0 ]]; then
        log_error "Could not read db_recovery_file_dest from the primary (sqlplus exit ${_fra_rc})"
        log_error "  $(_first_ora_line "$FRA_PRIMARY_PARAMS_RAW")"
        log_error "Refusing to start the non-restartable RMAN duplicate without this check. Nothing has been changed."
        exit 1
    fi

    parse_primary_fra_params "$FRA_PRIMARY_PARAMS_RAW"
    if [[ "$PRIMARY_FRA_QUERY_OK" != "YES" ]]; then
        log_error "The primary's db_recovery_file_dest query returned no completion row - cannot tell whether it has an FRA"
        log_error "  $(_first_ora_line "$FRA_PRIMARY_PARAMS_RAW")"
        log_error "Refusing to start the non-restartable RMAN duplicate without this check. Nothing has been changed."
        exit 1
    fi

    # Cross-check against what step 1 recorded; the live value decides.
    if [[ "$(fra_normalize_path "$PRIMARY_FRA_DEST")" != "$(fra_normalize_path "${DB_RECOVERY_FILE_DEST:-}")" ]]; then
        log_warn "Primary db_recovery_file_dest differs from the config's record (live: '$(fra_display_path "${PRIMARY_FRA_DEST:-}")', recorded: '$(fra_display_path "${DB_RECOVERY_FILE_DEST:-}")') - using the live value"
    fi

    if [[ -n "$PRIMARY_FRA_DEST" ]]; then
        LIVE_PRIMARY_FRA_DEST="$PRIMARY_FRA_DEST"
        log_info "Primary has an FRA: $(fra_display_path "$PRIMARY_FRA_DEST") (size ${PRIMARY_FRA_SIZE:-unset})"
        log_info "Clearing the primary's FRA $(fra_display_path "$PRIMARY_FRA_DEST") on the standby because USE_FRA_FOR_STANDBY=NO"
        log_info "  (RMAN SPFILE clause: RESET DB_RECOVERY_FILE_DEST, RESET DB_RECOVERY_FILE_DEST_SIZE)"
        log_warn "Without an FRA the standby cannot enable Flashback Database (needed to reinstate the old primary after an FSFO failover)"
    else
        log_info "Primary has no db_recovery_file_dest - nothing inherited to clear"
    fi

    # Other primary destinations that resolve into the FRA would be invalid
    # on a standby without one. Warn, never rewrite them silently.
    if [[ -n "$PRIMARY_FRA_ARCHIVE_DESTS" ]]; then
        log_warn "Primary uses LOCATION=USE_DB_RECOVERY_FILE_DEST in: ${PRIMARY_FRA_ARCHIVE_DESTS}"
        log_warn "  The standby inherits these but has no FRA, so they will be invalid there (log_archive_dest_1 is set explicitly below)."
        log_warn "  Review them after the clone (broker manages the DG destinations; local ones need an explicit LOCATION=<dir>)."
    fi
fi

# ============================================================
# Broker Configuration Files (best effort, both storage modes)
# ============================================================
# RMAN DUPLICATE ... SPFILE copies the primary's spfile, so an EXPLICIT
# dg_broker_config_file1/2 on the primary (a path under the primary's
# ORACLE_HOME, say) would be inherited and may not exist on this host. When
# the primary sets them, point the standby's at its own dbs directory, named
# after the standby DB_UNIQUE_NAME (the default naming). When both are
# defaults, set nothing: that keeps read-only-home defaults working. Not a
# blocker - the broker files are re-created - so a failed query only warns.
BROKER_FILE_SETS=""
pause_verbose_trace
_bcf_rc=0
BROKER_CFG_RAW=$(sqlplus -s /nolog <<SQL 2>&1
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${SYS_PASSWORD}"@${PRIMARY_TNS_ALIAS} AS SYSDBA
@${SQL_DIR}/queries/get_dg_broker_config_files.sql
SQL
) || _bcf_rc=$?
resume_verbose_trace

if [[ $_bcf_rc -ne 0 ]]; then
    log_warn "Could not read dg_broker_config_file1/2 from the primary (sqlplus exit ${_bcf_rc}): $(_first_ora_line "$BROKER_CFG_RAW")"
    log_warn "Continuing; if the primary sets them to explicit paths, the standby inherits those - fix with ALTER SYSTEM after the clone"
else
    _bcf_explicit=0
    for _bcf_name in dg_broker_config_file1 dg_broker_config_file2; do
        _bcf_line=$(printf '%s\n' "$BROKER_CFG_RAW" | tr -d '\r' | grep -i "^${_bcf_name}|" | head -1) || _bcf_line=""
        [[ -z "$_bcf_line" ]] && continue
        _bcf_default=$(printf '%s' "$_bcf_line" | awk -F'|' '{print toupper($NF)}')
        if [[ "$_bcf_default" == "FALSE" ]]; then
            _bcf_explicit=1
            log_info "Primary sets ${_bcf_name} explicitly: $(printf '%s' "$_bcf_line" | awk -F'|' '{print $2}')"
        fi
    done
    if [[ $_bcf_explicit -eq 1 ]]; then
        _bcf_dir="${ORACLE_HOME}/dbs"
        if is_safe_omf_dest_path "$_bcf_dir"; then
            BROKER_FILE_SETS="
    SET DG_BROKER_CONFIG_FILE1='${_bcf_dir}/dr1${STANDBY_DB_UNIQUE_NAME}.dat'
    SET DG_BROKER_CONFIG_FILE2='${_bcf_dir}/dr2${STANDBY_DB_UNIQUE_NAME}.dat'"
            log_info "Standby dg_broker_config_file1/2 will be set to ${_bcf_dir}/dr[12]${STANDBY_DB_UNIQUE_NAME}.dat (the inherited primary paths would not apply here)"
        else
            log_warn "ORACLE_HOME dbs directory '${_bcf_dir}' has characters not safe for RMAN - not setting dg_broker_config_file1/2"
            log_warn "The standby will inherit the primary's explicit paths; fix with ALTER SYSTEM after the clone"
        fi
    else
        log_info "Primary uses default dg_broker_config_file1/2 - nothing to override"
    fi
fi

# ============================================================
# Start Instance in NOMOUNT
# ============================================================

progress_step "Starting Standby Instance"

# The typed confirmation comes BEFORE anything is touched: the SHUTDOWN ABORT
# below used to run first, so declining left the standby down. Declining now
# changes nothing and exits non-zero.
if ! confirm_typed_value "This will start the non-restartable RMAN duplicate for ${STANDBY_DB_UNIQUE_NAME}." "${STANDBY_DB_UNIQUE_NAME}"; then
    log_warn "RMAN duplicate cancelled by user - nothing was changed"
    exit 1
fi

# Check if instance is already running (a leftover auxiliary instance from an
# earlier attempt, normally)
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>&1 || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

if echo "$INSTANCE_STATUS" | grep -qE "STARTED|MOUNTED|OPEN"; then
    log_warn "Instance ${ORACLE_SID} is already running (status: ${INSTANCE_STATUS})"

    # ORACLE_SID alone picks the instance, so a wrong SID/host would abort a
    # primary. A NOMOUNT (STARTED) instance has no V$DATABASE yet and is the
    # expected leftover auxiliary, so it is allowed. Once the control file is
    # read (MOUNTED/OPEN) it must report PHYSICAL STANDBY, else refuse.
    if [[ "$INSTANCE_STATUS" != "STARTED" ]]; then
        EXISTING_ROLE=$(run_sql_query "get_db_role.sql" 2>/dev/null | tr -d '\r' | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }') || EXISTING_ROLE=""
        if [[ "$EXISTING_ROLE" != "PHYSICAL STANDBY" ]]; then
            log_error "The running instance ${ORACLE_SID} is ${INSTANCE_STATUS} with database role '${EXISTING_ROLE:-unknown}', not PHYSICAL STANDBY"
            log_error "Refusing to SHUTDOWN ABORT it. Check ORACLE_SID/ORACLE_HOME and that this is the standby host."
            log_error "If it really is the leftover standby instance, shut it down yourself and re-run this step."
            exit 1
        fi
        log_info "Existing instance is a PHYSICAL STANDBY (leftover from an earlier attempt)"
    fi

    log_info "Shutting down existing instance..."
    log_cmd "sqlplus / as sysdba:" "SHUTDOWN ABORT"
    run_sql_command "shutdown_abort.sql"
fi

log_info "Starting instance in NOMOUNT mode..."
log_cmd "sqlplus / as sysdba:" "STARTUP NOMOUNT PFILE='${PFILE}'"
run_sql_command "startup_nomount.sql" "$PFILE"

# Verify NOMOUNT state
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

if [[ "$INSTANCE_STATUS" != "STARTED" ]]; then
    log_error "Failed to start instance in NOMOUNT mode"
    log_error "Current status: $INSTANCE_STATUS"
    exit 1
fi

log_info "Instance started in NOMOUNT mode"

# ============================================================
# Execute RMAN Duplicate
# ============================================================

progress_step "Executing RMAN Duplicate"

echo ""
echo "================================================================"
echo "Starting RMAN duplicate from active database..."
echo "This process may take a while depending on database size."
echo "Watch the RMAN output below for channel allocation, restore, and recovery progress."
echo "================================================================"
echo ""

# Create RMAN script (cmdfile). It will hold the CONNECT TARGET/AUXILIARY
# lines (see below) needed to authenticate to primary and standby, so SYS
# credentials never appear on the rman process argv (visible via `ps -ef`
# for the life of the call). Because it briefly holds those credentials it
# must live in a local, private, mode-600 temp directory - never on the
# shared NFS share - and be removed on every exit path. RMAN runs locally
# against the local RMAN client, so a local temp dir works fine; only the
# RMAN log (unchanged, below) still goes to the NFS share.
# Private temp dir + EXIT-trap cleanup: create_temp_dir prefers `mktemp -d`,
# falling back to a mode-700 directory on AIX images without mktemp - safer
# than a predictable /tmp/..._$$ filename. No pre-existing EXIT trap in this
# script, so it is safe to install one here.
RMAN_TMP_DIR=$(create_temp_dir) || { log_error "Could not create temp directory"; exit 1; }
trap 'rm -rf "$RMAN_TMP_DIR"' EXIT
RMAN_SCRIPT="${RMAN_TMP_DIR}/rman_duplicate_$(date '+%Y%m%d_%H%M%S').rcv"
# Create the file and lock down permissions BEFORE any credential is written to it.
: > "$RMAN_SCRIPT"
chmod 600 "$RMAN_SCRIPT"

# Determine LOG_ARCHIVE_DEST_1 setting based on storage mode and FRA usage
if [[ "$STANDBY_STORAGE_MODE" == "OMF" || "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
else
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
fi

# Build optional RUN { ... } wrapper with channel allocation. Allocated only
# when channels > 1 or rate is set; otherwise the bare DUPLICATE statement is
# used (preserving the default behavior: RMAN picks its own channels).
#
# Why BOTH target and auxiliary channels: ACTIVE duplication has two methods
# and the channel type that does the work differs (Oracle 19c Backup and
# Recovery User's Guide, "Duplicating Databases"):
#   - image copies ("push"): the TARGET channels do the principal work;
#   - backup sets ("pull"): the AUXILIARY channels do it.
# This step connects to the primary by net service name and uses neither
# USING BACKUPSET nor SECTION SIZE, so RMAN picks backup sets exactly when
# (auxiliary channels allocated) >= (target channels allocated), else image
# copies. Allocating only auxiliary channels left the target side at the
# primary's CONFIGURE PARALLELISM, so a primary configured with more channels
# than --channels silently flipped to push and --rate (set on the auxiliary
# channels) throttled nothing. Allocating the same number on both sides keeps
# the method deterministic (equal => backup sets) and puts the rate on every
# channel that can do the work.
RMAN_PROLOGUE=""
RMAN_EPILOGUE=""
if [[ "$RMAN_CHANNELS" -gt 1 || -n "$RMAN_RATE" ]]; then
    _rate_clause=""
    [[ -n "$RMAN_RATE" ]] && _rate_clause=" RATE $RMAN_RATE"

    _channel_lines=""
    _i=1
    while [[ $_i -le $RMAN_CHANNELS ]]; do
        _channel_lines="${_channel_lines}  ALLOCATE CHANNEL tgt${_i} TYPE DISK${_rate_clause};
  ALLOCATE AUXILIARY CHANNEL aux${_i} TYPE DISK${_rate_clause};
"
        _i=$((_i + 1))
    done

    RMAN_PROLOGUE="RUN {
${_channel_lines}"
    RMAN_EPILOGUE="}"

    log_info "RMAN tuning: ${RMAN_CHANNELS} target + ${RMAN_CHANNELS} auxiliary channel(s)${RMAN_RATE:+, rate ${RMAN_RATE} per channel}"
fi

# DIAGNOSTIC_DEST: step 2's pfile sets it from the standby ORACLE_BASE, but
# the pfile is only used to start the auxiliary instance - the SPFILE that
# DUPLICATE builds is the primary's copy plus the SET list, so without this
# the standby keeps the primary's ADR base (wrong when the ORACLE_BASE
# differs). Skipped for a config that predates STANDBY_ORACLE_BASE.
DIAG_DEST_SET=""
if [[ -n "${STANDBY_ORACLE_BASE:-}" ]]; then
    DIAG_DEST_SET="
    SET DIAGNOSTIC_DEST='${STANDBY_ORACLE_BASE}'"
fi

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: use db_create_file_dest, no FILE_NAME_CONVERT
    RMAN_BODY=$(cat <<EOF
# RMAN Duplicate for Standby (OMF Mode, Data Guard Broker Managed)
# Generated: $(date)
# Note: DG parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.) will be
#       configured by Data Guard Broker after duplication completes.

${RMAN_PROLOGUE}
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${STANDBY_DB_UNIQUE_NAME}'${DIAG_DEST_SET}${BROKER_FILE_SETS}
    SET DB_CREATE_FILE_DEST='${STANDBY_DB_CREATE_FILE_DEST}'${OMF_ONLINE_LOG_DEST_SETS}
    SET DB_RECOVERY_FILE_DEST='${STANDBY_DB_RECOVERY_FILE_DEST}'
    SET DB_RECOVERY_FILE_DEST_SIZE='${STANDBY_DB_RECOVERY_FILE_DEST_SIZE}'
    SET LOG_ARCHIVE_DEST_1='${LOG_ARCHIVE_DEST_1_SETTING}'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET DG_BROKER_START='FALSE'
    SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_LISTENER_PORT}))'
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
${RMAN_EPILOGUE}
EOF
)
else
    # Traditional mode: use FILE_NAME_CONVERT (existing behavior)
    # FRA lines: USE_FRA_FOR_STANDBY=YES -> SET both; otherwise, when the live
    # primary has an FRA, RESET both (the SPFILE is the primary's copy, so
    # they would be inherited); a primary without one -> no line at all.
    # See build_rman_fra_lines above.
    FRA_SETTINGS=$(build_rman_fra_lines "$STANDBY_STORAGE_MODE" "$USE_FRA_FOR_STANDBY" "${STANDBY_FRA:-}" "${STANDBY_DB_RECOVERY_FILE_DEST_SIZE:-${DB_RECOVERY_FILE_DEST_SIZE}}" "$LIVE_PRIMARY_FRA_DEST")

    RMAN_BODY=$(cat <<EOF
# RMAN Duplicate for Standby (Data Guard Broker Managed)
# Generated: $(date)
# Note: DG parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.) will be
#       configured by Data Guard Broker after duplication completes.

${RMAN_PROLOGUE}
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${STANDBY_DB_UNIQUE_NAME}'${DIAG_DEST_SET}${BROKER_FILE_SETS}
    SET CONTROL_FILES='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_CONTROL_FILE_2_DIR:-$STANDBY_DATA_PATH}/control02.ctl'
    SET LOG_ARCHIVE_DEST_1='${LOG_ARCHIVE_DEST_1_SETTING}'
${FRA_SETTINGS}
    SET DB_FILE_NAME_CONVERT=${DB_FILE_NAME_CONVERT}
    SET LOG_FILE_NAME_CONVERT=${LOG_FILE_NAME_CONVERT}
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET DG_BROKER_START='FALSE'
    SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_LISTENER_PORT}))'
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
${RMAN_EPILOGUE}
EOF
)
fi

# Write the CONNECT lines first (RMAN requires TARGET/AUXILIARY connected
# before DUPLICATE can run), then the duplicate statement body. The file
# was created with chmod 600 above, before either password was written.
# xtrace is paused around the password-bearing printf lines (C2).
pause_verbose_trace
{
    printf 'CONNECT TARGET SYS/"%s"@%s;\n' "${SYS_PASSWORD}" "${PRIMARY_TNS_ALIAS}"
    printf 'CONNECT AUXILIARY SYS/"%s"@%s;\n' "${SYS_PASSWORD}" "${STANDBY_TNS_ALIAS}"
    printf '%s\n' "$RMAN_BODY"
} >> "$RMAN_SCRIPT"
resume_verbose_trace

log_info "RMAN script created: $RMAN_SCRIPT"
# RMAN masks credentials in its own echo of a script-embedded CONNECT
# command (it prints "connect target *" / "connect auxiliary *", never the
# literal connect string), so the RMAN_LOG produced below does not capture
# the password either. As a second layer, the diagnostic dump below only
# ever logs the non-credential DUPLICATE body - never the CONNECT lines.
log_detail "RMAN script contents (CONNECT lines redacted):"
log_detail "  CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS};"
log_detail "  CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS};"
while IFS= read -r line; do
    log_detail "  $line"
done <<< "$RMAN_BODY"
record_artifact "rman_script:${RMAN_SCRIPT} (transient - deleted after this run)"

# Execute RMAN
RMAN_LOG="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').log"

log_info "Starting RMAN duplicate (logging to: $RMAN_LOG)..."
log_cmd "rman" "cmdfile ${RMAN_SCRIPT}  # CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS}, CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS}"
echo ""
confirm_approval_action "Run RMAN duplicate for standby creation" "\"$ORACLE_HOME/bin/rman\" cmdfile ${RMAN_SCRIPT}  # cmdfile opens with CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS} and CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS}" || exit 1

# Use tee to display output on screen AND write to log file
# AIX compatible: use temp file to capture exit code instead of PIPESTATUS.
# Reuse RMAN_TMP_DIR (created above, mode 700, already covered by the
# EXIT-trap installed above) for the exit-code file too.
RMAN_EXIT_FILE="${RMAN_TMP_DIR}/rman_exit.$$"
# Disable errexit around the pipeline so an RMAN failure still writes the
# exit-code file and reaches the failure-handling block below.
set +e
(
"$ORACLE_HOME/bin/rman" cmdfile "${RMAN_SCRIPT}"
echo $? > "$RMAN_EXIT_FILE"
) 2>&1 | tee "$RMAN_LOG"
set -e

RMAN_EXIT_CODE=$(cat "$RMAN_EXIT_FILE" 2>/dev/null || echo "1")

# Remove the cmdfile (and exit-code file) now that RMAN is done with them -
# the cmdfile held SYS credentials. The EXIT trap above remains the safety
# net for early/abnormal exits; this is the prompt cleanup on the normal path.
rm -rf "$RMAN_TMP_DIR"

# Clear password from memory
SYS_PASSWORD=""

if [[ $RMAN_EXIT_CODE -ne 0 ]]; then
    log_error "RMAN duplicate failed with exit code: $RMAN_EXIT_CODE"
    log_error "Please check the RMAN log: $RMAN_LOG"

    # M10: this step is not restartable once RMAN duplicate has started -
    # the reset procedure was only printed once, in "Reviewing Planned
    # Changes", several minutes/many lines of RMAN output ago. Re-print it
    # here with the actual concrete paths for this build so it's still on
    # screen (and in the log) right where the failure just happened.
    if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
        RESET_DATA_NOTE="Remove standby files under: ${STANDBY_DB_CREATE_FILE_DEST}, ${STANDBY_DB_RECOVERY_FILE_DEST}"
        # db_create_online_log_dest_n directories also hold standby redo
        # logs / control files (ASM '+' values are cleaned up in ASM)
        _n=1
        while [[ $_n -le 5 ]]; do
            eval "_olog_dir=\$RESOLVED_OLOG_DEST_${_n}"
            [[ -n "$_olog_dir" ]] && RESET_DATA_NOTE="${RESET_DATA_NOTE}, ${_olog_dir}"
            _n=$((_n + 1))
        done
    else
        RESET_DATA_PATHS=("$STANDBY_DATA_PATH")
        if [[ -n "${STANDBY_DATA_PATHS+x}" && ${#STANDBY_DATA_PATHS[@]} -gt 0 ]]; then
            RESET_DATA_PATHS=("${STANDBY_DATA_PATHS[@]}")
        fi
        RESET_REDO_PATHS=("$STANDBY_REDO_PATH")
        if [[ -n "${STANDBY_REDO_PATHS+x}" && ${#STANDBY_REDO_PATHS[@]} -gt 0 ]]; then
            RESET_REDO_PATHS=("${STANDBY_REDO_PATHS[@]}")
        fi
        RESET_SRL_NOTE=""
        if [[ -n "${STANDBY_SRL_PATH:-}" && "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
            RESET_SRL_NOTE=", ${STANDBY_SRL_PATH}"
        fi
        RESET_DATA_NOTE="Remove standby datafiles/controlfiles under: $(shell_join "${RESET_DATA_PATHS[@]}"); redo logs under: $(shell_join "${RESET_REDO_PATHS[@]}")${RESET_SRL_NOTE}"
    fi

    echo ""
    print_list_block "This Step Is NOT Directly Restartable - Reset Procedure" \
        "Shut down the standby instance: ORACLE_SID=${STANDBY_ORACLE_SID} sqlplus / as sysdba, then SHUTDOWN ABORT." \
        "$RESET_DATA_NOTE" \
        "Review the RMAN log first to confirm which files actually exist before deleting anything: ${RMAN_LOG}" \
        "Re-run ./standby/05_clone_standby.sh after correcting the failure."

    exit 1
fi

log_success "RMAN duplicate completed successfully"
record_artifact "rman_log:${RMAN_LOG}"

# ============================================================
# Create SPFILE and Restart
# ============================================================

progress_step "Finalizing Instance Configuration"

# Check if we're mounted
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

log_info "Current instance status: $INSTANCE_STATUS"

# The RMAN duplicate with SPFILE option must have created an spfile. If it is
# missing, do NOT build one from the minimal step-3 pfile (sga_target=0,
# processes=300, no primary memory settings): that would silently give the
# standby a different parameter set than the primary. Accept an spfile the
# instance reports being started with; otherwise fail and point at the log.
SPFILE="${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora"
if [[ -f "$SPFILE" ]]; then
    log_info "SPFILE exists: $SPFILE"
else
    SPFILE_IN_USE=$(get_db_parameter "spfile" 2>/dev/null) || SPFILE_IN_USE=""
    if [[ -n "$SPFILE_IN_USE" ]]; then
        SPFILE="$SPFILE_IN_USE"
        log_info "SPFILE in use: $SPFILE"
    else
        log_error "RMAN reported success but no SPFILE exists at $SPFILE and the instance is not running from one"
        log_error "Not creating one from the minimal pfile: it lacks the primary's parameters (memory, processes, ...)"
        log_error "Review the RMAN log for the SPFILE/restore section: $RMAN_LOG"
        exit 1
    fi
fi
record_artifact "spfile:${SPFILE}"

# Read back the standby's effective FRA parameters and compare them with the
# choice made in step 2: the SPFILE is the primary's copy plus the SET/RESET
# list, so this is where an inherited FRA (or a lost one) would show. A
# value that cannot be read only warns - the clone itself succeeded. A
# CONTRADICTION is recorded (FRA_CHECK_FAILED) and logged here, but does NOT
# exit: the DUPLICATE is done and this step is not restartable, so the
# remaining post-clone actions (broker start, MRP, deletion policy) must still
# run; the script then ends non-zero with the error block repeated.
FRA_CHECK_FAILED=0
FRA_CHECK_MSG=""
FRA_CHECK_FIX_1=""
FRA_CHECK_FIX_2=""
FRA_CHECK_WHY=""
# Print the recorded FRA contradiction (used where it happens and again at the end).
print_fra_check_failure() {
    log_error "FRA check failed: ${FRA_CHECK_MSG}"
    log_error "${FRA_CHECK_WHY}"
    log_error "The clone itself is complete - do not re-run this step. Manual fix on the standby (sqlplus / as sysdba):"
    log_error "  ${FRA_CHECK_FIX_1}"
    log_error "  ${FRA_CHECK_FIX_2}"
}
if [[ "$STANDBY_STORAGE_MODE" == "OMF" || "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
    _fra_expect="YES"
    _fra_expected_path="${STANDBY_FRA:-${STANDBY_DB_RECOVERY_FILE_DEST:-}}"
    [[ "$STANDBY_STORAGE_MODE" == "OMF" ]] && _fra_expected_path="${STANDBY_DB_RECOVERY_FILE_DEST:-}"
else
    _fra_expect="NO"
    _fra_expected_path=""
fi
# run_sql_query (not get_db_parameter) so a failed read is seen as one: the
# latter always returns 0 and would hand ORA- text to the comparison.
_read_standby_param() {
    local _o
    _o=$(run_sql_query "get_db_parameter.sql" "$1" 2>/dev/null) || return 1
    printf '%s' "$_o" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n'
}
_fra_have_values=1
STANDBY_FRA_DEST_ACTUAL=$(_read_standby_param "db_recovery_file_dest") || _fra_have_values=0
STANDBY_FRA_SIZE_ACTUAL=$(_read_standby_param "db_recovery_file_dest_size") || _fra_have_values=0
if [[ $_fra_have_values -eq 0 ]]; then
    log_warn "Could not read the standby's db_recovery_file_dest / db_recovery_file_dest_size - FRA configuration not verified"
else
    log_info "Standby effective db_recovery_file_dest: '$(fra_display_path "${STANDBY_FRA_DEST_ACTUAL:-}")' (size: ${STANDBY_FRA_SIZE_ACTUAL:-unset})"
    _fra_rc=0
    _fra_msg=$(fra_readback_verdict "$_fra_expect" "$_fra_expected_path" "$STANDBY_FRA_DEST_ACTUAL" "$STANDBY_FRA_SIZE_ACTUAL") || _fra_rc=$?
    case $_fra_rc in
        0) log_info "FRA check: ${_fra_msg}" ;;
        2) log_warn "FRA check: ${_fra_msg}" ;;
        *)
            FRA_CHECK_FAILED=1
            FRA_CHECK_MSG="$_fra_msg"
            if [[ "$_fra_expect" == "NO" ]]; then
                FRA_CHECK_WHY="The primary's FRA setting was inherited despite USE_FRA_FOR_STANDBY=NO (RMAN RESET did not take effect)."
                FRA_CHECK_FIX_1="ALTER SYSTEM SET db_recovery_file_dest='' SCOPE=BOTH;"
                FRA_CHECK_FIX_2="ALTER SYSTEM RESET db_recovery_file_dest_size SCOPE=SPFILE;"
            else
                # the size must be set before the destination
                FRA_CHECK_WHY="The standby's FRA does not match the configuration."
                FRA_CHECK_FIX_1="ALTER SYSTEM SET db_recovery_file_dest_size=${STANDBY_DB_RECOVERY_FILE_DEST_SIZE:-${DB_RECOVERY_FILE_DEST_SIZE:-<size>}} SCOPE=BOTH;"
                FRA_CHECK_FIX_2="ALTER SYSTEM SET db_recovery_file_dest='${_fra_expected_path}' SCOPE=BOTH;"
            fi
            print_fra_check_failure
            log_error "RMAN log: $RMAN_LOG"
            log_error "Continuing with the remaining post-clone actions (broker start, MRP, deletion policy); this step will exit non-zero at the end."
            ;;
    esac
fi

# ============================================================
# Start Managed Recovery
# ============================================================

progress_step "Starting Managed Recovery"

log_info "Starting managed recovery process (MRP)..."
log_cmd "sqlplus / as sysdba:" "ALTER DATABASE MOUNT STANDBY DATABASE"
log_cmd "sqlplus / as sysdba:" "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION"

# RMAN DUPLICATE ... FOR STANDBY normally leaves the auxiliary instance
# already MOUNTED once the duplicate completes, so re-issuing MOUNT STANDBY
# DATABASE here would raise ORA-01100 (database already mounted) now that
# mount_standby.sql aborts on SQL errors. Only mount if it isn't already.
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

if [[ "$INSTANCE_STATUS" == "MOUNTED" ]]; then
    log_info "Standby instance is already mounted (left MOUNTED by RMAN duplicate) - skipping MOUNT STANDBY DATABASE"
else
    run_sql_command "mount_standby.sql"
fi

# The duplicate ran with DG_BROKER_START='FALSE' (deliberately: with the
# broker up DURING the clone, a leftover broker configuration file from an
# earlier standby build - which the documented re-clone reset procedure
# never removes - makes DMON start managed recovery mid-duplicate and the
# duplicate dies with ORA-01153; found live in the E2E run). Now that the
# clone is complete: clear any stale broker config files for this standby
# at their default location while the broker is still down, then enable it.
for _dr_file in "${ORACLE_HOME}/dbs/dr1${STANDBY_DB_UNIQUE_NAME}.dat" "${ORACLE_HOME}/dbs/dr2${STANDBY_DB_UNIQUE_NAME}.dat"; do
    if [[ -f "$_dr_file" ]]; then
        log_warn "Removing stale broker configuration file from a previous build: $_dr_file"
        rm -f "$_dr_file"
    fi
done
log_info "Enabling Data Guard Broker on the standby (was disabled during the duplicate)..."
log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH"
run_sql_command "set_dg_broker_start.sql"

run_sql_command "start_mrp.sql"

# Verify MRP is running
sleep 5

# A transient failure here must not abort the step after a successful clone;
# an empty result just falls through to the "could not be verified" warning.
MRP_STATUS=$(run_sql_query "get_mrp_status.sql" 2>/dev/null) || MRP_STATUS=""

if echo "$MRP_STATUS" | grep -q "MRP0"; then
    log_info "Managed Recovery Process (MRP) is running"
    log_info "Status: $MRP_STATUS"
else
    log_warn "MRP status could not be verified"
    log_warn "Please check V\$MANAGED_STANDBY manually"
fi

# L15: refresh the instance status here. The last assignment above was
# taken BEFORE the MOUNT STANDBY DATABASE / start_mrp.sql calls just above
# - the final summary block below used to print that pre-mount value
# (typically "STARTED") even though the instance is mounted and applying
# by this point.
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

# ============================================================
# Display Status
# ============================================================

log_section "Standby Database Status"

echo ""
echo "Database Role and Status:"
run_sql_display "get_db_status.sql"

echo ""
echo "Managed Standby Processes:"
run_sql_display "get_managed_standby_procs.sql"

echo ""
echo "Archive Log Apply Status:"
run_sql_display "get_archive_apply_status.sql"

# ============================================================
# Configure RMAN Archivelog Deletion Policy
# ============================================================

log_section "Configuring RMAN Archivelog Deletion Policy"

log_info "Setting archivelog deletion policy to SHIPPED TO ALL STANDBY..."
log_cmd "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY"

run_rman "configure_archivelog_deletion.rman"

log_success "RMAN archivelog deletion policy configured"

# ============================================================
# Summary
# ============================================================

if [[ "$FRA_CHECK_FAILED" == "1" ]]; then
    _final_status="ERROR"
    _final_msg="Standby cloned, but its FRA setting contradicts the configuration - fix it before step 6"
else
    _final_status="SUCCESS"
    _final_msg="Standby database created successfully"
fi
print_summary "$_final_status" "$_final_msg"
print_status_block "Standby Clone Result" \
    "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
    "Instance Status" "$INSTANCE_STATUS" \
    "MRP Verification" "${MRP_STATUS:-Unavailable}" \
    "FRA Check" "$([[ "$FRA_CHECK_FAILED" == "1" ]] && printf 'FAILED - %s' "$FRA_CHECK_MSG" || printf 'OK / not applicable')" \
    "RMAN Log" "$RMAN_LOG"

print_list_block "Completed Actions" \
    "Started the standby instance in NOMOUNT." \
    "Ran RMAN DUPLICATE FROM ACTIVE DATABASE." \
    "Verified the SPFILE and read back the standby's effective FRA settings." \
    "Started Managed Recovery Process (MRP)." \
    "Configured RMAN archivelog deletion policy."

if [[ "$FRA_CHECK_FAILED" == "1" ]]; then
    echo ""
    print_fra_check_failure
    log_error "The remaining post-clone actions (broker start, MRP, archivelog deletion policy) WERE carried out."
    log_error "Do NOT run ./primary/06_configure_broker.sh until the FRA setting above is fixed."
    exit 1
fi

print_list_block "Next Steps" \
    "On PRIMARY, run ./primary/06_configure_broker.sh to enable broker-managed log shipping." \
    "Then run ./standby/07_verify_dataguard.sh to validate the full setup."

echo ""
echo "Note: Log shipping will not be fully managed until broker configuration is complete."

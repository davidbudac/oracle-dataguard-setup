#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/scenario.sh - load a scenario and its primary profile
# =============================================================================
#   load_scenario ID        source scenarios/<ID>_*.scenario.env and its
#                           primaries/<P>_*.env, apply S_PRIMARY_OVERRIDES,
#                           expand the lab placeholders, derive the names the
#                           other libraries use, compute S_NEEDS
#   scenario_file ID        path of the scenario file
#   scenario_ids [TIER]     ids, in catalog order, optionally filtered by tier
#
# Placeholders (expanded in every P_*, WANT_*, CASE_*, S_* and EXPECT_* value):
#   {FS1} {FS2} {FS3}   the lab's writable base directories (LAB_FS_SLOTS),
#                       distinct FIRST path components - the scripts' Q1b
#                       treats the first component as "the filesystem"
#   {FSn:fs}            the first component of slot n (/home for /home/oracle)
#   {RENAME}            LAB_FS_RENAME_TARGET: a world-writable first component
#                       (/tmp) the "renamed filesystem" scenarios map onto
#   {SCRATCH}           LAB_SCRATCH (per-host scratch root, oracle-owned)
#   ${ORACLE_BASE}      plain shell expansion at source time (config.env sets it)
#
# Derived variables (read by provision/build/checks/proofs):
#   SCN_ID SCN_TIER SCN_KIND
#   P_SID P_DB_UNIQUE_NAME        defaulted from P_DB_NAME
#   SCN_STANDBY_NAME              WANT_STANDBY_DB_UNIQUE_NAME (default <db>_s)
#   SCN_STANDBY_SID               WANT_STANDBY_SID or P_SID
#   SCN_NET                       scratch | shared
#   SCN_PORT                      listener port the scenario uses
#   E2E_REMOTE_SID                primary SID for ssh_* on the PRIMARY token
#   E2E_REMOTE_TNS_ADMIN          scratch TNS_ADMIN dir ("" = shared home)
#   SCN_WORK                      per-scenario scratch dir on the hosts
#   S_NEEDS                       space-separated prerequisites for the doctor
# =============================================================================

[[ -n "${E2E_SCENARIO_LOADED:-}" ]] && return 0
E2E_SCENARIO_LOADED=1

scenario_file() {
    local id="$1" f
    for f in "${SCENARIO_DIR}/${id}_"*.scenario.env; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

profile_file() {
    local id="$1" f
    for f in "${SCENARIO_DIR}/primaries/${id}_"*.env; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

scenario_ids() {
    local tier="${1:-}" f id
    for f in "${SCENARIO_DIR}"/[sr][0-9][0-9]_*.scenario.env; do
        [[ -f "$f" ]] || continue
        id=$(basename "$f"); id="${id%%_*}"
        if [[ -n "$tier" && "$tier" != "full" ]]; then
            local t; t=$(sed -n 's/^S_TIER="\([a-z]*\)".*/\1/p' "$f")
            case "$tier" in
                smoke) [[ "$t" == "smoke" ]] || continue ;;
                core)  [[ "$t" == "smoke" || "$t" == "core" ]] || continue ;;
            esac
        fi
        printf '%s\n' "$id"
    done
}

# Expand the {..} placeholders in one string.
expand_placeholders() {
    local s="$1" n slot
    local slots=( $LAB_FS_SLOTS )
    n=1
    for slot in "${slots[@]}"; do
        s="${s//\{FS${n}\}/${slot}}"
        s="${s//\{FS${n}:fs\}/$(fs_of "$slot")}"
        n=$((n + 1))
    done
    s="${s//\{RENAME\}/${LAB_FS_RENAME_TARGET:-/tmp}}"
    s="${s//\{SCRATCH\}/${LAB_SCRATCH}}"
    printf '%s' "$s"
}

# Does the string still reference a slot the lab does not provide?
_unexpanded_slot() {
    case "$1" in
        *\{FS[0-9]\}*|*\{FS[0-9]:fs\}*) return 0 ;;
    esac
    return 1
}

_expand_all_vars() {
    local v val new
    for v in $(compgen -A variable | grep -E '^(P_|WANT_|CASE_|S_|EXPECT_|PROVE_|INJECT_|OPERATOR_)'); do
        val="${!v}"
        case "$val" in
            *\{*\}*)
                new=$(expand_placeholders "$val")
                printf -v "$v" '%s' "$new"
                if _unexpanded_slot "$new"; then
                    SCN_MISSING_SLOTS="${SCN_MISSING_SLOTS} ${v}"
                fi
                ;;
        esac
    done
}

# Reset every scenario/profile variable so two load_scenario calls in one
# process do not leak keys from the previous one.
_reset_scenario_vars() {
    local v
    # SCN_LOG belongs to the runner (where this scenario's logs go), not to
    # the scenario: it must survive a reload.
    for v in $(compgen -A variable | grep -E '^(P_|WANT_|CASE_|S_|EXPECT_|PROVE_|INJECT_|OPERATOR_|SCN_)' | grep -vx 'SCN_LOG'); do
        unset "$v"
    done
}

load_scenario() {
    local id="$1" sfile pfile kv
    sfile=$(scenario_file "$id") || { log_error "No scenario '${id}' under ${SCENARIO_DIR}"; return 1; }
    _reset_scenario_vars
    SCN_MISSING_SLOTS=""

    # Scenario first (it names the profile), then the profile, then the
    # scenario again so its WANT_/S_ keys win and S_PRIMARY_OVERRIDES applies.
    # shellcheck disable=SC1090
    source "$sfile"
    pfile=$(profile_file "$S_PRIMARY") || { log_error "Scenario ${id}: unknown primary profile '${S_PRIMARY}'"; return 1; }
    # shellcheck disable=SC1090
    source "$pfile"
    # shellcheck disable=SC1090
    source "$sfile"
    for kv in ${S_PRIMARY_OVERRIDES:-}; do
        printf -v "${kv%%=*}" '%s' "${kv#*=}"
    done

    _expand_all_vars

    SCN_ID="$S_ID"
    SCN_TIER="${S_TIER:-full}"
    SCN_KIND="${S_KIND:-build}"
    SCN_FILE="$sfile"
    SCN_PROFILE_FILE="$pfile"

    P_SID="${P_SID:-$P_DB_NAME}"
    P_DB_UNIQUE_NAME="${P_DB_UNIQUE_NAME:-$P_DB_NAME}"
    P_LISTENER_PORT="${P_LISTENER_PORT:-1521}"
    P_CDB="${P_CDB:-no}"
    P_STORAGE="${P_STORAGE:-explicit}"
    P_REDO_GROUPS="${P_REDO_GROUPS:-3}"
    P_REDO_SIZE_MB="${P_REDO_SIZE_MB:-200}"
    P_ARCHIVELOG="${P_ARCHIVELOG:-yes}"
    P_FORCE_LOGGING="${P_FORCE_LOGGING:-yes}"
    P_PWFILE="${P_PWFILE:-exclusive}"
    P_FLASHBACK="${P_FLASHBACK:-no}"
    P_PRE_SRL="${P_PRE_SRL:-none}"
    P_PRE_SRL_THREAD="${P_PRE_SRL_THREAD:-explicit}"
    P_SEED_MB="${P_SEED_MB:-0}"
    P_LOAD_DURING_CLONE="${P_LOAD_DURING_CLONE:-no}"
    P_MEMORY_MB="${P_MEMORY_MB:-$TEST_DB_MEMORY_MB}"
    [[ "$P_CDB" == "yes" && "$P_MEMORY_MB" -lt 1536 ]] && P_MEMORY_MB=1536

    SCN_STANDBY_NAME="${WANT_STANDBY_DB_UNIQUE_NAME:-${P_DB_NAME}_s}"
    # marker schema for the proofs: a common user on a CDB
    MARK_USER="e2e"; [[ "$P_CDB" == "yes" ]] && MARK_USER='c##e2e'
    MARK_PASSWORD="e2e_Mark_1"
    export MARK_USER MARK_PASSWORD
    SCN_STANDBY_SID="${WANT_STANDBY_SID:-$P_SID}"
    SCN_NET="${S_NET:-scratch}"
    SCN_PORT="$P_LISTENER_PORT"
    SCN_WORK="${LAB_SCRATCH}/${SCN_ID}"
    E2E_REMOTE_SID="$P_SID"
    if [[ "$SCN_NET" == "scratch" ]]; then
        E2E_REMOTE_TNS_ADMIN="${LAB_SCRATCH}/net_${SCN_ID}"
        # The shared listener owns 1521; a scratch network needs its own port.
        [[ "$SCN_PORT" == "1521" ]] && SCN_PORT="${LAB_SCRATCH_PORT:-1531}"
    else
        E2E_REMOTE_TNS_ADMIN=""
    fi
    export E2E_REMOTE_SID E2E_REMOTE_TNS_ADMIN

    # Prerequisites the doctor resolves against what the lab really has.
    local needs="python3"
    local all_paths="${P_DATA_DIRS:-} ${P_REDO_DIRS:-} ${P_TEMP_DIR:-} ${P_CONTROL_FILES:-} ${P_OMF_FILE_DEST:-} ${P_FRA_DIR:-} ${P_ARCHIVE_DEST:-} ${WANT_OMF_FILE_DEST:-} ${WANT_SEPARATE_SRL_DIR:-} ${WANT_CONTROL_FILE_2_DIR:-} ${WANT_STANDBY_FRA:-} ${WANT_PATH_OVERRIDES:-}"
    local slots=( $LAB_FS_SLOTS ) n=1 slot
    for slot in "${slots[@]}"; do
        [[ $n -ge 2 ]] && case " $all_paths " in *"${slot}"*) needs="$needs fs${n}" ;; esac
        n=$((n + 1))
    done
    [[ -n "${SCN_MISSING_SLOTS}" ]] && needs="$needs fs-missing"
    [[ -n "${WANT_FS_MAP:-}" ]] && needs="$needs rename-target"
    [[ -n "${WANT_STANDBY_ORACLE_BASE:-}" ]] && needs="$needs obase-sibling"
    [[ "${WANT_OBSERVER:-none}" == "third-host" ]] && needs="$needs host3"
    [[ "${WANT_FSFO:-no}" == "yes" || "${PROVE_FAILOVER:-no}" == "yes" ]] && needs="$needs flashback-space"
    [[ "$P_CDB" == "yes" ]] && needs="$needs mem2g" || needs="$needs mem1g"
    [[ "${S_NEEDS:-}" ]] && needs="$needs ${S_NEEDS}"
    S_NEEDS="$needs"
    return 0
}

# Print the resolved scenario as KEY=VALUE lines (for logs/result.json).
scenario_dump() {
    local v
    for v in $(compgen -A variable | grep -E '^(P_|WANT_|S_|PROVE_|EXPECT_|SCN_)' | sort); do
        printf '%s=%s\n' "$v" "${!v}"
    done
}

#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/doctor.sh - what the lab can do, and what each scenario needs
# =============================================================================
#   doctor_probe            probe both hosts (and HOST3), write logs/lab.caps
#   doctor_load             read logs/lab.caps into CAP_* variables
#   doctor_unmet NEEDS      print the unmet prerequisites of a NEEDS string,
#                           one per line as "<need>: <how to fix>"
#   doctor_report           table of every scenario: RUNNABLE / SKIP reason
#
# Capabilities (lab.caps, KEY=VALUE):
#   CAP_SSH_PRIMARY CAP_SSH_STANDBY CAP_SSH_HOST3  yes|no
#   CAP_PY_PRIMARY CAP_PY_STANDBY                  python3 version or no
#   CAP_HOME_PRIMARY CAP_HOME_STANDBY              yes|no (sqlplus, dbca, rman, dgmgrl)
#   CAP_NFS_PRIMARY CAP_NFS_STANDBY                yes|no (writable share)
#   CAP_MEM_PRIMARY CAP_MEM_STANDBY                MemAvailable MB
#   CAP_SUDO_PRIMARY CAP_SUDO_STANDBY              yes|no (passwordless)
#   CAP_SLOTn_PRIMARY CAP_SLOTn_STANDBY            ok|<reason> for each LAB_FS_SLOTS entry
#   CAP_SLOTn_FREE_PRIMARY/_STANDBY                free MB on that slot
#   CAP_RENAME_STANDBY                              ok|<reason> for LAB_FS_RENAME_TARGET
#   CAP_OBASE_SIBLING_STANDBY                       yes|no (dirname(ORACLE_BASE) writable)
#   CAP_HOST3_DGMGRL                                yes|no
#   CAP_PORT_FREE_PRIMARY/_STANDBY                  yes|no (LAB_SCRATCH_PORT not listening)
# =============================================================================

[[ -n "${E2E_DOCTOR_LOADED:-}" ]] && return 0
E2E_DOCTOR_LOADED=1

CAPS_FILE="${LOG_ROOT}/lab.caps"

_probe_host_script() {
    # Emits KEY=VALUE lines with the suffix $1 (PRIMARY/STANDBY)
    local sfx="$1" n=1 slot
    cat <<REMOTE
set +e
echo "CAP_SSH_${sfx}=yes"
if command -v python3 >/dev/null 2>&1; then echo "CAP_PY_${sfx}=\$(python3 -c 'import sys,pty;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || echo no)"; else echo "CAP_PY_${sfx}=no"; fi
ok=yes; for b in sqlplus dbca rman dgmgrl lsnrctl; do [[ -x "\$ORACLE_HOME/bin/\$b" ]] || ok=no; done; echo "CAP_HOME_${sfx}=\$ok"
if [[ -d "\$NFS_SHARE" ]] && touch "\$NFS_SHARE/.e2e_probe" 2>/dev/null; then rm -f "\$NFS_SHARE/.e2e_probe"; echo "CAP_NFS_${sfx}=yes"; else echo "CAP_NFS_${sfx}=no"; fi
echo "CAP_MEM_${sfx}=\$(awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
if sudo -n true >/dev/null 2>&1; then echo "CAP_SUDO_${sfx}=yes"; else echo "CAP_SUDO_${sfx}=no"; fi
echo "CAP_HOSTNAME_${sfx}=\$(hostname)"
if (exec 3<>/dev/tcp/127.0.0.1/${LAB_SCRATCH_PORT:-1531}) 2>/dev/null; then echo "CAP_PORT_FREE_${sfx}=no"; else echo "CAP_PORT_FREE_${sfx}=yes"; fi
probe_dir() {
    d="\$1"
    if [[ ! -d "\$d" ]]; then mkdir -p "\$d" 2>/dev/null || { echo "missing (mkdir -p \$d failed)"; return; }; fi
    [[ -w "\$d" ]] || { echo "not writable by \$(id -un)"; return; }
    fst=\$(df -P "\$d" 2>/dev/null | awk 'NR==2{print \$1}')
    typ=\$(findmnt -no FSTYPE -T "\$d" 2>/dev/null || stat -f -c %T "\$d" 2>/dev/null)
    [[ "\$typ" == "tmpfs" ]] && { echo "tmpfs (memory-backed)"; return; }
    echo ok
}
REMOTE
    for slot in $LAB_FS_SLOTS; do
        cat <<REMOTE
echo "CAP_SLOT${n}_${sfx}=\$(probe_dir $(shq "$slot"))"
echo "CAP_SLOT${n}_FREE_${sfx}=\$(df -Pk $(shq "$slot") 2>/dev/null | awk 'NR==2{print int(\$4/1024)}' || echo 0)"
REMOTE
        n=$((n + 1))
    done
    if [[ "$sfx" == "STANDBY" ]]; then
        cat <<REMOTE
rt=$(shq "${LAB_FS_RENAME_TARGET:-/tmp}")
if [[ -d "\$rt" && -w "\$rt" ]]; then
    typ=\$(findmnt -no FSTYPE -T "\$rt" 2>/dev/null); if [[ "\$typ" == "tmpfs" ]]; then echo "CAP_RENAME_STANDBY=tmpfs"; else echo "CAP_RENAME_STANDBY=ok"; fi
else echo "CAP_RENAME_STANDBY=not writable"; fi
echo "CAP_RENAME_FREE_STANDBY=\$(df -Pk "\$rt" 2>/dev/null | awk 'NR==2{print int(\$4/1024)}' || echo 0)"
if [[ -w "\$(dirname "\$ORACLE_BASE")" ]]; then echo "CAP_OBASE_SIBLING_STANDBY=yes"; else echo "CAP_OBASE_SIBLING_STANDBY=no"; fi
REMOTE
    fi
}

doctor_probe() {
    mkdir -p "$LOG_ROOT"
    local tmp="${CAPS_FILE}.tmp" token script
    : > "$tmp"
    printf '# lab capabilities probed %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$tmp"
    for token in PRIMARY STANDBY; do
        if ssh_reachable "$token"; then
            script="${LOG_ROOT}/.probe_${token}.sh"
            _probe_host_script "$token" > "$script"
            ssh_script "$token" "$script" "" | grep '^CAP_' >> "$tmp"
            rm -f "$script"
        else
            printf 'CAP_SSH_%s=no\n' "$token" >> "$tmp"
        fi
    done
    if [[ -n "${HOST3:-}" ]]; then
        if ssh_reachable HOST3; then
            printf 'CAP_SSH_HOST3=yes\n' >> "$tmp"
            ssh_cmd HOST3 '[[ -x "$ORACLE_HOME/bin/dgmgrl" ]] && echo CAP_HOST3_DGMGRL=yes || echo CAP_HOST3_DGMGRL=no; echo "CAP_HOSTNAME_HOST3=$(hostname)"' "" | grep '^CAP_' >> "$tmp"
        else
            printf 'CAP_SSH_HOST3=no\nCAP_HOST3_DGMGRL=no\n' >> "$tmp"
        fi
    else
        printf 'CAP_SSH_HOST3=unconfigured\nCAP_HOST3_DGMGRL=no\n' >> "$tmp"
    fi
    mv "$tmp" "$CAPS_FILE"
    doctor_load
}

doctor_load() {
    [[ -f "$CAPS_FILE" ]] || return 1
    local line
    while IFS= read -r line; do
        case "$line" in
            CAP_*=*) printf -v "${line%%=*}" '%s' "${line#*=}" ;;
        esac
    done < "$CAPS_FILE"
    return 0
}

_cap() { local v="CAP_$1"; printf '%s' "${!v:-}"; }

# doctor_unmet "NEEDS" -> lines "<need>: <fix>" for what the lab lacks
doctor_unmet() {
    local need n slots=( $LAB_FS_SLOTS ) slot
    for need in $1; do
        case "$need" in
            python3)
                [[ "$(_cap PY_PRIMARY)" != "no" && -n "$(_cap PY_PRIMARY)" && "$(_cap PY_STANDBY)" != "no" && -n "$(_cap PY_STANDBY)" ]] \
                    || echo "python3: install python3 on both DB hosts (dnf install python3)" ;;
            fs[2-9])
                n="${need#fs}"; slot="${slots[$((n - 1))]:-}"
                if [[ -z "$slot" ]]; then
                    echo "${need}: LAB_FS_SLOTS has no slot ${n}; add a writable directory with a distinct first path component (e.g. /home/${SSH_USER}, /var/tmp/${SSH_USER})"
                else
                    [[ "$(_cap "SLOT${n}_PRIMARY")" == "ok" ]] || echo "${need}: slot ${n} (${slot}) on the primary: $(_cap "SLOT${n}_PRIMARY") - fix: mkdir -p ${slot} && chown ${SSH_USER} ${slot}"
                    [[ "$(_cap "SLOT${n}_STANDBY")" == "ok" ]] || echo "${need}: slot ${n} (${slot}) on the standby: $(_cap "SLOT${n}_STANDBY") - fix: mkdir -p ${slot} && chown ${SSH_USER} ${slot}"
                fi ;;
            fs-missing)
                echo "fs-missing: the scenario references a {FSn} slot that LAB_FS_SLOTS does not define" ;;
            rename-target)
                [[ "$(_cap RENAME_STANDBY)" == "ok" ]] || echo "rename-target: ${LAB_FS_RENAME_TARGET:-/tmp} on the standby: $(_cap RENAME_STANDBY) - set LAB_FS_RENAME_TARGET to a world-writable, disk-backed top-level directory" ;;
            obase-sibling)
                [[ "$(_cap OBASE_SIBLING_STANDBY)" == "yes" ]] || echo "obase-sibling: $(dirname "$ORACLE_BASE") on the standby is not writable by ${SSH_USER} (needed for a different standby ORACLE_BASE) - fix as root: chown ${SSH_USER} $(dirname "$ORACLE_BASE")" ;;
            host3)
                [[ "$(_cap SSH_HOST3)" == "yes" ]] || echo "host3: set HOST3 in config.env to a reachable third host (currently: $(_cap SSH_HOST3))"
                [[ "$(_cap SSH_HOST3)" != "yes" || "$(_cap HOST3_DGMGRL)" == "yes" ]] || echo "host3: no dgmgrl under HOST3_ORACLE_HOME on ${HOST3}" ;;
            flashback-space)
                [[ "${CAP_SLOT1_FREE_PRIMARY:-0}" -ge 8000 && "${CAP_SLOT1_FREE_STANDBY:-0}" -ge 8000 ]] || echo "flashback-space: fewer than 8 GB free on slot 1 (primary ${CAP_SLOT1_FREE_PRIMARY:-?} MB, standby ${CAP_SLOT1_FREE_STANDBY:-?} MB)" ;;
            # MemAvailable is a pessimistic guide for Oracle (SGA pages are
            # touched lazily): a 1 GB pair has run with 650 MB "available".
            # Gate only on the hopeless cases; LAB_MEM_MIN_1G/2G override.
            mem1g)
                [[ "${CAP_MEM_PRIMARY:-0}" -ge "${LAB_MEM_MIN_1G:-600}" && "${CAP_MEM_STANDBY:-0}" -ge "${LAB_MEM_MIN_1G:-600}" ]] || echo "mem1g: under ${LAB_MEM_MIN_1G:-600} MB available (primary ${CAP_MEM_PRIMARY:-?} MB, standby ${CAP_MEM_STANDBY:-?} MB) - stop other instances or grow the VMs" ;;
            mem2g)
                [[ "${CAP_MEM_PRIMARY:-0}" -ge "${LAB_MEM_MIN_2G:-1200}" && "${CAP_MEM_STANDBY:-0}" -ge "${LAB_MEM_MIN_2G:-1200}" ]] || echo "mem2g: under ${LAB_MEM_MIN_2G:-1200} MB available (primary ${CAP_MEM_PRIMARY:-?} MB, standby ${CAP_MEM_STANDBY:-?} MB) - a CDB pair needs it; stop other instances (e.g. the lab's cdb1 pair) or grow the VMs" ;;
            scratch-port)
                [[ "$(_cap PORT_FREE_PRIMARY)" == "yes" && "$(_cap PORT_FREE_STANDBY)" == "yes" ]] || echo "scratch-port: port ${LAB_SCRATCH_PORT:-1531} is in use on a DB host - set LAB_SCRATCH_PORT to a free one" ;;
            *) echo "${need}: unknown prerequisite (typo in S_NEEDS?)" ;;
        esac
    done
}

# Basics every scenario needs; printed by `e2e.sh doctor`
doctor_basics() {
    local ok=1
    [[ "$(_cap SSH_PRIMARY)" == "yes" ]] && log_pass "ssh primary ${PRIMARY_HOST}:${PRIMARY_SSH_PORT} ($(_cap HOSTNAME_PRIMARY))" || { log_fail "ssh primary ${PRIMARY_HOST}:${PRIMARY_SSH_PORT}"; ok=0; }
    [[ "$(_cap SSH_STANDBY)" == "yes" ]] && log_pass "ssh standby ${STANDBY_HOST}:${STANDBY_SSH_PORT} ($(_cap HOSTNAME_STANDBY))" || { log_fail "ssh standby ${STANDBY_HOST}:${STANDBY_SSH_PORT}"; ok=0; }
    case "$(_cap SSH_HOST3)" in
        yes) log_pass "ssh third host ${HOST3} ($(_cap HOSTNAME_HOST3)), dgmgrl: $(_cap HOST3_DGMGRL)" ;;
        unconfigured) log_info "no HOST3 configured (third-host observer scenarios will be skipped)" ;;
        *) log_warn "HOST3 ${HOST3} unreachable (third-host observer scenarios will be skipped)" ;;
    esac
    local t
    for t in PRIMARY STANDBY; do
        [[ "$(_cap SSH_$t)" == "yes" ]] || continue
        [[ "$(_cap HOME_$t)" == "yes" ]] && log_pass "$t: Oracle home ${ORACLE_HOME}" || { log_fail "$t: ${ORACLE_HOME} lacks sqlplus/dbca/rman/dgmgrl/lsnrctl"; ok=0; }
        [[ "$(_cap PY_$t)" != "no" && -n "$(_cap PY_$t)" ]] && log_pass "$t: python3 $(_cap PY_$t) (prompt driver)" || { log_fail "$t: python3 missing - the prompt driver needs it"; ok=0; }
        [[ "$(_cap NFS_$t)" == "yes" ]] && log_pass "$t: NFS share writable at ${NFS_SHARE}" || { log_fail "$t: NFS share ${NFS_SHARE} not writable"; ok=0; }
        log_info "$t: MemAvailable $(_cap MEM_$t) MB, sudo: $(_cap SUDO_$t), port ${LAB_SCRATCH_PORT:-1531} free: $(_cap PORT_FREE_$t)"
        local n=1 slot
        for slot in $LAB_FS_SLOTS; do
            local st; st=$(_cap "SLOT${n}_$t")
            [[ "$st" == "ok" ]] && log_pass "$t: slot ${n} ${slot} ($(_cap "SLOT${n}_FREE_$t") MB free)" || log_warn "$t: slot ${n} ${slot}: ${st}"
            n=$((n + 1))
        done
    done
    [[ "$(_cap SSH_STANDBY)" == "yes" ]] && log_info "standby: rename target ${LAB_FS_RENAME_TARGET:-/tmp}: $(_cap RENAME_STANDBY) ($(_cap RENAME_FREE_STANDBY) MB free); sibling of ORACLE_BASE writable: $(_cap OBASE_SIBLING_STANDBY)"
    [[ $ok -eq 1 ]]
}

doctor_report() {
    local id unmet tier
    printf '\n  %-5s %-6s %-9s %s\n' "ID" "TIER" "STATUS" "TITLE / UNMET PREREQUISITES"
    for id in $(scenario_ids); do
        load_scenario "$id" >/dev/null 2>&1 || { printf '  %-5s %-6s %-9s %s\n' "$id" "?" "BROKEN" "cannot load"; continue; }
        unmet=$(doctor_unmet "$S_NEEDS")
        if [[ -z "$unmet" ]]; then
            printf '  %-5s %-6s %b%-9s%b %s\n' "$id" "$SCN_TIER" "$GREEN" "RUNNABLE" "$NC" "${S_TITLE}"
        else
            printf '  %-5s %-6s %b%-9s%b %s\n' "$id" "$SCN_TIER" "$YELLOW" "SKIP" "$NC" "${S_TITLE}"
            printf '%s\n' "$unmet" | sed 's/^/                          - /'
        fi
    done
    printf '\n'
}

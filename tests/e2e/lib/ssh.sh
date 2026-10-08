#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/ssh.sh - reach the lab hosts
# =============================================================================
# Hosts are addressed by TOKEN, never by hostname: PRIMARY, STANDBY, HOST3.
# (Two hosts may share a hostname with different ports - localhost:2201/2202.)
#
#   ssh_cmd  TOKEN "shell snippet"            run as the oracle user, Oracle env set
#   ssh_sql  TOKEN "SQL" [SID]                 sqlplus / as sysdba, trimmed output
#   ssh_sql_raw TOKEN "SQL" [SID]              same, untrimmed (multi-row)
#   ssh_dgmgrl TOKEN "DGMGRL command" [SID]    dgmgrl -silent /
#   ssh_script TOKEN "path" [SID]              pipe a local script to bash -s on the host
#   deploy_tree TOKEN                          rsync the working tree to REPO_DIR
#
# The remote environment for a scenario (ORACLE_SID, TNS_ADMIN) comes from
# E2E_REMOTE_SID / E2E_REMOTE_TNS_ADMIN, set by lib/scenario.sh. Every
# function takes an optional SID override as its last argument.
# =============================================================================

[[ -n "${E2E_SSH_LOADED:-}" ]] && return 0
E2E_SSH_LOADED=1

E2E_REMOTE_SID="${E2E_REMOTE_SID:-}"
E2E_REMOTE_TNS_ADMIN="${E2E_REMOTE_TNS_ADMIN:-}"

_host_of() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_HOST" ;;
        STANDBY) printf '%s' "$STANDBY_HOST" ;;
        HOST3)   printf '%s' "${HOST3:-}" ;;
        *) echo "ssh.sh: unknown host token '$1'" >&2; return 1 ;;
    esac
}
_port_of() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_SSH_PORT" ;;
        STANDBY) printf '%s' "$STANDBY_SSH_PORT" ;;
        HOST3)   printf '%s' "$HOST3_SSH_PORT" ;;
    esac
}
_home_of() {
    case "$1" in
        HOST3) printf '%s' "$HOST3_ORACLE_HOME" ;;
        *)     printf '%s' "$ORACLE_HOME" ;;
    esac
}

# The environment prefix every remote command runs under.
_remote_env() {
    local token="$1" sid="${2:-$E2E_REMOTE_SID}"
    local home; home=$(_home_of "$token")
    printf 'export ORACLE_HOME=%s ORACLE_BASE=%s NFS_SHARE=%s LIBPATH=%s/lib LD_LIBRARY_PATH=%s/lib; ' \
        "$(shq "$home")" "$(shq "$ORACLE_BASE")" "$(shq "$NFS_SHARE")" "$(shq "$home")" "$(shq "$home")"
    printf 'export PATH=%s/bin:$PATH; ' "$(shq "$home")"
    [[ -n "$sid" ]] && printf 'export ORACLE_SID=%s; ' "$(shq "$sid")"
    if [[ -n "$E2E_REMOTE_TNS_ADMIN" ]]; then
        printf 'export TNS_ADMIN=%s; ' "$(shq "$E2E_REMOTE_TNS_ADMIN")"
    else
        printf 'unset TNS_ADMIN; '
    fi
}

# ssh_cmd TOKEN "snippet" [SID]
# The snippet runs through "bash -s" on the host with the environment above
# already exported, so it may contain quotes, heredocs and $ freely - nothing
# is re-quoted through ssh's remote shell.
ssh_cmd() {
    local token="$1" snippet="$2" sid="${3:-}"
    local host port
    host=$(_host_of "$token") || return 1
    port=$(_port_of "$token")
    [[ -z "$host" ]] && { echo "ssh.sh: no host configured for $token" >&2; return 1; }
    {
        _remote_env "$token" "$sid"
        printf '\n%s\n' "$snippet"
    } | ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${JUMP_OPT} -p "$port" "${SSH_USER}@${host}" 'bash -s' 2>&1
}

# ssh_sql TOKEN "SQL" [SID] - single value, whitespace stripped
ssh_sql() {
    ssh_sql_raw "$@" | tr -d '[:space:]'
}

# ssh_sql_raw TOKEN "SQL" [SID] - full output, one row per line
ssh_sql_raw() {
    local token="$1" sql="$2" sid="${3:-}"
    ssh_cmd "$token" "sqlplus -s / as sysdba <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON TRIMSPOOL ON TAB OFF ECHO OFF VERIFY OFF
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE
${sql}
EXIT;
SQLEOF" "$sid" | sed '/^$/d'
}

# ssh_dgmgrl TOKEN "command" [SID]
ssh_dgmgrl() {
    local token="$1" cmd="$2" sid="${3:-}"
    ssh_cmd "$token" "dgmgrl -silent / $(shq "$cmd") 2>&1" "$sid"
}

# ssh_script TOKEN /local/path [SID] - run a local bash script on the host
ssh_script() {
    local token="$1" script="$2" sid="${3:-}"
    local host port
    host=$(_host_of "$token") || return 1
    port=$(_port_of "$token")
    {
        _remote_env "$token" "$sid"
        printf '\n'
        cat "$script"
    } | ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${JUMP_OPT} -p "$port" "${SSH_USER}@${host}" 'bash -s' 2>&1
}

# ssh_copy_to TOKEN /local/file /remote/path
ssh_copy_to() {
    local token="$1" src="$2" dst="$3"
    local host port
    host=$(_host_of "$token") || return 1
    port=$(_port_of "$token")
    ssh_cmd "$token" "mkdir -p $(shq "$(dirname "$dst")")" >/dev/null
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${JUMP_OPT} -p "$port" "${SSH_USER}@${host}" "cat > $(shq "$dst")" < "$src"
}

# ssh_reachable TOKEN -> 0/1
ssh_reachable() {
    local token="$1" host port
    host=$(_host_of "$token" 2>/dev/null) || return 1
    [[ -z "$host" ]] && return 1
    port=$(_port_of "$token")
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${JUMP_OPT} -o ConnectTimeout=8 -p "$port" \
        "${SSH_USER}@${host}" 'echo __E2E_OK__' 2>/dev/null | grep -q __E2E_OK__
}

# deploy_tree TOKEN - put the repository on the host at REPO_DIR
deploy_tree() {
    local token="$1" host port
    host=$(_host_of "$token") || return 1
    port=$(_port_of "$token")
    if [[ "$LOCAL_DEPLOY" == "true" ]]; then
        ssh_cmd "$token" "mkdir -p $(shq "$REPO_DIR")" >/dev/null 2>&1 || true
        rsync -az --delete --exclude='.git/' --exclude='tests/e2e/logs/' --exclude='.cursor/' \
            -e "ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${JUMP_OPT} -p ${port}" \
            "${REPO_ROOT}/" "${SSH_USER}@${host}:${REPO_DIR}/" 2>&1 || return 1
    else
        ssh_cmd "$token" "
            if [[ -d $(shq "$REPO_DIR")/.git ]]; then
                cd $(shq "$REPO_DIR") && git fetch origin $(shq "${REPO_BRANCH:-main}") && git checkout $(shq "${REPO_BRANCH:-main}") && git reset --hard origin/$(shq "${REPO_BRANCH:-main}")
            else
                mkdir -p $(shq "$(dirname "$REPO_DIR")") && git clone -b $(shq "${REPO_BRANCH:-main}") $(shq "$REPO_URL") $(shq "$REPO_DIR")
            fi" | grep -qvE '^(fatal|error)' || return 1
    fi
    ssh_cmd "$token" "chmod +x $(shq "$REPO_DIR")/*.sh $(shq "$REPO_DIR")/*/*.sh 2>/dev/null; true" >/dev/null
}

#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/provision.sh - build the PRIMARY described by a profile
# =============================================================================
#   provision_scenario      net (both hosts) -> DBCA -> reshape -> verify
#   provision_net TOKEN     scratch TNS_ADMIN + listener on SCN_PORT (scratch mode)
#   provision_db            DBCA from P_*, then the SQL that gives it the
#                           profile's shape (layout, archiving, FRA, services,
#                           PDBs, SRLs, broker files, convert params, seed)
#   verify_shape            prove the profile took, against the live database
#
# Everything runs on the PRIMARY token as the oracle user. The remote work is
# one generated bash script per phase (see _remote_*), piped to "bash -s" so
# quoting stays sane. The profile's P_* variables and the scenario's derived
# SCN_* variables (lib/scenario.sh) must be loaded.
# =============================================================================

[[ -n "${E2E_PROVISION_LOADED:-}" ]] && return 0
E2E_PROVISION_LOADED=1

# The host the DB host knows itself as (TNS/listener), per token.
oracle_hostname_of() {
    case "$1" in
        PRIMARY) printf '%s' "${PRIMARY_ORACLE_HOSTNAME:-$PRIMARY_HOST}" ;;
        STANDBY) printf '%s' "${STANDBY_ORACLE_HOSTNAME:-$STANDBY_HOST}" ;;
        HOST3)   printf '%s' "${HOST3_ORACLE_HOSTNAME:-${HOST3:-}}" ;;
    esac
}

# First data directory = where SYSTEM lives (explicit mode).
_first_dir() { local a=( $1 ); printf '%s' "${a[0]:-}"; }
_upper_unique() { upper "$P_DB_UNIQUE_NAME"; }

# ---------------------------------------------------------------------------
# Network: scratch TNS_ADMIN with its own listener (never touches the shared
# $ORACLE_HOME/network/admin, so the persistent lab databases are safe)
# ---------------------------------------------------------------------------
provision_net() {
    local token="$1"
    [[ "$SCN_NET" == "scratch" ]] || { log_info "${token}: shared network/admin (S_NET=shared)"; return 0; }
    local host; host=$(oracle_hostname_of "$token")
    local dir="$E2E_REMOTE_TNS_ADMIN"
    local out
    out=$(ssh_cmd "$token" "
set -e
mkdir -p $(shq "$dir") && chmod 750 $(shq "$dir")
cat > $(shq "$dir")/listener.ora <<EOF
# E2E scratch listener for scenario ${SCN_ID} (TNS_ADMIN=${dir})
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${host})(PORT = ${SCN_PORT}))
    )
  )
EOF
cat > $(shq "$dir")/sqlnet.ora <<EOF
# E2E scratch sqlnet.ora for scenario ${SCN_ID}
NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)
$( [[ -n "${P_NAMES_DEFAULT_DOMAIN:-}" ]] && printf 'NAMES.DEFAULT_DOMAIN = %s\n' "$P_NAMES_DEFAULT_DOMAIN" )
EOF
: > $(shq "$dir")/tnsnames.ora
lsnrctl stop >/dev/null 2>&1 || true
lsnrctl start 2>&1 | tail -3
lsnrctl status 2>&1 | grep -E 'PORT=|The listener supports|Listening Endpoints' | head -3
echo __NET_OK__
")
    if printf '%s' "$out" | grep -q __NET_OK__; then
        log_pass "${token}: scratch listener on port ${SCN_PORT} (TNS_ADMIN=${dir})"
    else
        log_fail "${token}: scratch listener setup failed"
        log_tail 8 "$out"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# DBCA
# ---------------------------------------------------------------------------
_dbca_args() {
    local gdb="$P_DB_NAME"
    [[ -n "${P_DB_DOMAIN:-}" ]] && gdb="${P_DB_NAME}.${P_DB_DOMAIN}"
    local args="-silent -createDatabase -gdbName $(shq "$gdb") -sid $(shq "$P_SID")"
    args="$args -templateName General_Purpose.dbc -sysPassword $(shq "$TEST_SYS_PASSWORD") -systemPassword $(shq "$TEST_SYS_PASSWORD")"
    args="$args -characterSet $(shq "$TEST_DB_CHARSET") -totalMemory ${P_MEMORY_MB} -emConfiguration NONE -storageType FS"
    args="$args -redoLogFileSize ${P_REDO_SIZE_MB} -databaseType MULTIPURPOSE"
    if [[ "$P_STORAGE" == "omf" ]]; then
        args="$args -useOMF true -datafileDestination $(shq "$P_OMF_FILE_DEST")"
    else
        args="$args -useOMF false -datafileDestination $(shq "$(dirname "$(_first_dir "$P_DATA_DIRS")")")"
    fi
    if [[ -n "${P_FRA_DIR:-}" ]]; then
        args="$args -recoveryAreaDestination $(shq "$P_FRA_DIR") -recoveryAreaSize $(( ${P_FRA_SIZE_GB:-20} * 1024 ))"
    fi
    if [[ "$P_CDB" == "yes" ]]; then
        args="$args -createAsContainerDatabase true -numberOfPDBs 0"
    else
        args="$args -createAsContainerDatabase false"
    fi
    local initp="db_unique_name=${P_DB_UNIQUE_NAME}"
    [[ -n "${P_DB_DOMAIN:-}" ]] && initp="${initp},db_domain=${P_DB_DOMAIN}"
    args="$args -initParams $(shq "$initp")"
    printf '%s' "$args"
}

provision_db() {
    local t0 out
    t0=$(now_s)
    log_section "DBCA ${P_DB_NAME} (${P_DESC:-})"
    local dirs="${P_DATA_DIRS:-} ${P_REDO_DIRS:-} ${P_TEMP_DIR:-} ${P_OMF_FILE_DEST:-} ${P_OMF_ONLINE_LOG_DEST_1:-} ${P_OMF_ONLINE_LOG_DEST_2:-} ${P_FRA_DIR:-} ${P_BROKER_FILE_DIR:-} ${SCN_WORK}"
    [[ "${P_ARCHIVE_DEST:-}" != "FRA" && -n "${P_ARCHIVE_DEST:-}" ]] && dirs="$dirs ${P_ARCHIVE_DEST}"
    local cf; for cf in ${P_CONTROL_FILES:-}; do dirs="$dirs $(dirname "$cf")"; done
    local mk="" d; for d in $dirs; do mk="$mk $(shq "$d")"; done

    out=$(ssh_cmd "PRIMARY" "
mkdir -p $mk || exit 1
mkdir -p $(shq "$(dirname "$(_first_dir "${P_DATA_DIRS:-$P_OMF_FILE_DEST}")")")
dbca $(_dbca_args) 2>&1
echo DBCA_EXIT_CODE=\$?
" | tee "${SCN_LOG}/provision/dbca.log")
    if printf '%s' "$out" | grep -q 'DBCA_EXIT_CODE=0'; then
        :
    elif printf '%s' "$out" | grep -q 'DBCA_EXIT_CODE=6' && printf '%s' "$out" | grep -qi 'Database creation complete'; then
        log_info "DBCA exited 6 (completed with warnings)"
    else
        log_fail "DBCA failed for ${P_DB_NAME}"
        log_tail 15 "$out"
        return 1
    fi
    log_pass "DBCA created ${P_DB_NAME} in $(fmt_elapsed $(( $(now_s) - t0 )))"
}

# ---------------------------------------------------------------------------
# Reshape: the generated SQL that turns DBCA's output into the profile
# ---------------------------------------------------------------------------
_sql_redo_rebuild() {
    # Online redo rebuilt as groups 1..N in P_REDO_DIRS (one member per dir)
    # or, in OMF mode, in db_create_online_log_dest_n. Two rounds (temporary
    # groups 11.., then the final numbering); every step is "create if
    # missing / drop what is there", so an interrupted run can be repeated.
    local n="$P_REDO_GROUPS" size="$P_REDO_SIZE_MB" dirs="${P_REDO_DIRS:-}"
    local tmp_members="" fin_members="" d tmp_add fin_add
    for d in $dirs; do
        tmp_members="${tmp_members:+${tmp_members}, }''${d}/redo_tmp' || g || '.log''"
        fin_members="${fin_members:+${fin_members}, }''${d}/redo_0' || g || '.log''"
    done
    if [[ "$P_STORAGE" == "omf" ]]; then
        tmp_add="'ALTER DATABASE ADD LOGFILE GROUP ' || g || ' SIZE ${size}M'"
        fin_add="$tmp_add"
    else
        tmp_add="'ALTER DATABASE ADD LOGFILE GROUP ' || g || ' (${tmp_members}) SIZE ${size}M REUSE'"
        fin_add="'ALTER DATABASE ADD LOGFILE GROUP ' || g || ' (${fin_members}) SIZE ${size}M REUSE'"
    fi
    cat <<SQL
-- online redo: groups 1..${n} in the profile's directories (idempotent two-round rebuild)
DECLARE
  PROCEDURE drop_group(p_group IN NUMBER) IS
    v_status VARCHAR2(20);
  BEGIN
    LOOP
      SELECT status INTO v_status FROM v\$log WHERE group# = p_group;
      EXIT WHEN v_status IN ('INACTIVE', 'UNUSED');
      EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
      EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';
    END LOOP;
    EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || p_group;
  END;
  FUNCTION group_exists(p_group IN NUMBER) RETURN BOOLEAN IS
    v_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_n FROM v\$log WHERE group# = p_group;
    RETURN v_n > 0;
  END;
BEGIN
  FOR g IN 11..$((10 + n)) LOOP
    IF NOT group_exists(g) THEN EXECUTE IMMEDIATE ${tmp_add}; END IF;
  END LOOP;
  FOR r IN (SELECT group# FROM v\$log WHERE group# < 11 ORDER BY group#) LOOP
    drop_group(r.group#);
  END LOOP;
  FOR g IN 1..${n} LOOP
    IF NOT group_exists(g) THEN EXECUTE IMMEDIATE ${fin_add}; END IF;
  END LOOP;
  FOR r IN (SELECT group# FROM v\$log WHERE group# >= 11 ORDER BY group#) LOOP
    drop_group(r.group#);
  END LOOP;
END;
/
SQL
}

_sql_datafile_layout() {
    # Explicit mode: SYSTEM & co. into the first data dir, USERS into the
    # second (if any), tempfile into P_TEMP_DIR. Idempotent.
    [[ "$P_STORAGE" == "omf" ]] && return 0
    local d1 d2 tdir
    d1=$(_first_dir "$P_DATA_DIRS")
    d2=$(set -- $P_DATA_DIRS; printf '%s' "${2:-}")
    tdir="${P_TEMP_DIR:-$d1}"
    cat <<SQL
-- every datafile of the root/non-CDB into ${d1} (online move; a no-op when DBCA put it there)
BEGIN
  FOR r IN (SELECT file#, name FROM v\$datafile WHERE con_id IN (0,1)
             AND SUBSTR(name, 1, INSTR(name, '/', -1) - 1) <> '${d1}') LOOP
    EXECUTE IMMEDIATE 'ALTER DATABASE MOVE DATAFILE ' || r.file# || ' TO ''${d1}/' || SUBSTR(r.name, INSTR(r.name, '/', -1) + 1) || '''';
  END LOOP;
END;
/
SQL
    if [[ -n "$d2" ]]; then
        cat <<SQL
-- USERS onto the second data directory
BEGIN
  FOR r IN (SELECT d.file#, d.name FROM v\$datafile d JOIN v\$tablespace t ON t.ts# = d.ts# AND t.con_id = d.con_id
             WHERE d.con_id IN (0,1) AND t.name = 'USERS'
             AND SUBSTR(d.name, 1, INSTR(d.name, '/', -1) - 1) <> '${d2}') LOOP
    EXECUTE IMMEDIATE 'ALTER DATABASE MOVE DATAFILE ' || r.file# || ' TO ''${d2}/' || SUBSTR(r.name, INSTR(r.name, '/', -1) + 1) || '''';
  END LOOP;
END;
/
SQL
    fi
    cat <<SQL
-- tempfiles cannot be moved: one per temp tablespace in ${tdir}, the rest dropped
DECLARE
  v_n NUMBER;
BEGIN
  FOR r IN (SELECT DISTINCT t.name ts FROM v\$tablespace t JOIN v\$tempfile f ON f.ts# = t.ts# AND f.con_id = t.con_id WHERE t.con_id IN (0,1)) LOOP
    SELECT COUNT(*) INTO v_n FROM v\$tempfile WHERE con_id IN (0,1) AND name = '${tdir}/' || LOWER(r.ts) || '02.dbf';
    IF v_n = 0 THEN
      EXECUTE IMMEDIATE 'ALTER TABLESPACE ' || r.ts || ' ADD TEMPFILE ''${tdir}/' || LOWER(r.ts) || '02.dbf'' SIZE 200M REUSE AUTOEXTEND ON NEXT 100M MAXSIZE 4G';
    END IF;
    FOR f IN (SELECT name FROM v\$tempfile WHERE con_id IN (0,1) AND name <> '${tdir}/' || LOWER(r.ts) || '02.dbf') LOOP
      EXECUTE IMMEDIATE 'ALTER DATABASE TEMPFILE ''' || f.name || ''' DROP INCLUDING DATAFILES';
    END LOOP;
  END LOOP;
END;
/
SQL
}

_sql_pdbs() {
    [[ "$P_CDB" == "yes" && -n "${P_PDBS:-}" ]] || return 0
    local pdb d1
    d1=$(_first_dir "${P_DATA_DIRS:-}")
    for pdb in $P_PDBS; do
        if [[ "$P_STORAGE" == "omf" ]]; then
            cat <<SQL
BEGIN
  EXECUTE IMMEDIATE 'CREATE PLUGGABLE DATABASE ${pdb} ADMIN USER pdbadmin IDENTIFIED BY "${TEST_SYS_PASSWORD}"';
EXCEPTION WHEN OTHERS THEN IF SQLCODE <> -65012 THEN RAISE; END IF;
END;
/
SQL
        else
            cat <<SQL
DECLARE
  v_seed VARCHAR2(512);
BEGIN
  SELECT SUBSTR(name, 1, INSTR(name, '/', -1)) INTO v_seed FROM v\$datafile WHERE con_id = 2 AND ROWNUM = 1;
  EXECUTE IMMEDIATE 'CREATE PLUGGABLE DATABASE ${pdb} ADMIN USER pdbadmin IDENTIFIED BY "${TEST_SYS_PASSWORD}" FILE_NAME_CONVERT = (''' || v_seed || ''', ''${d1}/$(upper "$pdb")/'')';
EXCEPTION WHEN OTHERS THEN IF SQLCODE <> -65012 THEN RAISE; END IF;
END;
/
SQL
        fi
    done
    cat <<'SQL'
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
SQL
}

_sql_services() {
    [[ -n "${P_SERVICES:-}" ]] || return 0
    local spec cont svc
    for spec in $P_SERVICES; do
        if [[ "$spec" == *:* ]]; then cont="${spec%%:*}"; svc="${spec#*:}"; else cont=""; svc="$spec"; fi
        if [[ -n "$cont" && "$(lower "$cont")" != "cdb" && "$(lower "$cont")" != 'cdb$root' ]]; then
            printf "ALTER SESSION SET CONTAINER = %s;\n" "$cont"
        fi
        cat <<SQL
BEGIN
  BEGIN DBMS_SERVICE.CREATE_SERVICE(service_name => '${svc}', network_name => '${svc}'); EXCEPTION WHEN OTHERS THEN IF SQLCODE <> -44303 THEN RAISE; END IF; END;
  DBMS_SERVICE.START_SERVICE('${svc}');
END;
/
SQL
        [[ -n "$cont" ]] && printf 'ALTER SESSION SET CONTAINER = CDB$ROOT;\n'
    done
}

_sql_srls() {
    [[ "$P_PRE_SRL" != "none" ]] || return 0
    local size="$P_REDO_SIZE_MB" thread="THREAD 1 " dir add
    [[ "$P_PRE_SRL" == "undersized" ]] && size=$(( P_REDO_SIZE_MB / 2 ))
    [[ "$P_PRE_SRL_THREAD" == "none" ]] && thread=""
    dir=$(_first_dir "${P_REDO_DIRS:-}")
    if [[ "$P_STORAGE" == "omf" ]]; then
        add="'ALTER DATABASE ADD STANDBY LOGFILE ${thread}SIZE ${size}M'"
    else
        add="'ALTER DATABASE ADD STANDBY LOGFILE ${thread}(''${dir}/srl' || LPAD(g, 2, '0') || '.log'') SIZE ${size}M REUSE'"
    fi
    cat <<SQL
-- pre-existing standby redo logs (${P_PRE_SRL}, $( [[ -n "$thread" ]] && echo "THREAD 1" || echo "no THREAD clause" )): $(( P_REDO_GROUPS + 1 )) groups
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM v\$standby_log;
  FOR g IN (v_n + 1)..$(( P_REDO_GROUPS + 1 )) LOOP
    EXECUTE IMMEDIATE ${add};
  END LOOP;
END;
/
SQL
}

_sql_seed() {
    local cont=""
    [[ "$P_CDB" == "yes" ]] && cont=" CONTAINER=ALL"
    cat <<SQL
-- marker schema used by the proofs (redo roundtrip, switchover, failover); a common user on a CDB; idempotent
DECLARE
  PROCEDURE run(p_sql IN VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1920, -955) THEN RAISE; END IF;
  END;
BEGIN
  run('CREATE USER ${MARK_USER} IDENTIFIED BY "${MARK_PASSWORD}" DEFAULT TABLESPACE users QUOTA UNLIMITED ON users${cont}');
  run('GRANT CREATE SESSION, CREATE TABLE TO ${MARK_USER}${cont}');
  run('CREATE TABLE ${MARK_USER}.marks (id NUMBER GENERATED ALWAYS AS IDENTITY, label VARCHAR2(200), ts TIMESTAMP DEFAULT SYSTIMESTAMP)');
  run('CREATE TABLE ${MARK_USER}.filler (id NUMBER, pad VARCHAR2(1000))');
END;
/
SQL
    if [[ "${P_SEED_MB:-0}" -gt 0 ]]; then
        cat <<SQL
-- about ${P_SEED_MB} MB of filler rows (once)
DECLARE
  v_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM ${MARK_USER}.filler;
  IF v_n = 0 THEN
    INSERT /*+ APPEND */ INTO ${MARK_USER}.filler SELECT level, RPAD('x', 1000, 'x') FROM dual CONNECT BY level <= ${P_SEED_MB} * 1000;
    COMMIT;
  END IF;
END;
/
SQL
    fi
}

_remote_reshape() {
    # The whole post-DBCA SQL, in order. Parameters that need a restart are
    # set first; one bounce; then the online work.
    local arch_dest fra_sql pw_sql conv_sql brk_sql cf_sql ll_sql host
    host=$(oracle_hostname_of PRIMARY)
    if [[ "${P_ARCHIVE_DEST:-}" == "FRA" ]]; then
        arch_dest="LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${P_DB_UNIQUE_NAME}"
    else
        arch_dest="LOCATION=${P_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${P_DB_UNIQUE_NAME}"
    fi
    local reset_sql=""
    if [[ -n "${P_FRA_DIR:-}" ]]; then
        fra_sql="ALTER SYSTEM SET db_recovery_file_dest_size = ${P_FRA_SIZE_GB:-20}G SCOPE=SPFILE;
ALTER SYSTEM SET db_recovery_file_dest = '${P_FRA_DIR}' SCOPE=SPFILE;"
    else
        fra_sql=""
        reset_sql="ALTER SYSTEM RESET db_recovery_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_recovery_file_dest_size SCOPE=SPFILE;"
    fi
    pw_sql="ALTER SYSTEM SET remote_login_passwordfile = $(upper "$P_PWFILE") SCOPE=SPFILE;"
    conv_sql=""
    case "${P_PRESET_CONVERT:-}" in
        log)  conv_sql="ALTER SYSTEM SET log_file_name_convert = '/nonexistent/primary_redo', '/nonexistent/standby_redo' SCOPE=SPFILE;" ;;
        db)   conv_sql="ALTER SYSTEM SET db_file_name_convert = '/nonexistent/primary_data', '/nonexistent/standby_data' SCOPE=SPFILE;" ;;
        both) conv_sql="ALTER SYSTEM SET log_file_name_convert = '/nonexistent/primary_redo', '/nonexistent/standby_redo' SCOPE=SPFILE;
ALTER SYSTEM SET db_file_name_convert = '/nonexistent/primary_data', '/nonexistent/standby_data' SCOPE=SPFILE;" ;;
    esac
    brk_sql=""
    if [[ -n "${P_BROKER_FILE_DIR:-}" ]]; then
        brk_sql="ALTER SYSTEM SET dg_broker_config_file1 = '${P_BROKER_FILE_DIR}/dr1${P_DB_UNIQUE_NAME}.dat' SCOPE=SPFILE;
ALTER SYSTEM SET dg_broker_config_file2 = '${P_BROKER_FILE_DIR}/dr2${P_DB_UNIQUE_NAME}.dat' SCOPE=SPFILE;"
    fi
    cf_sql=""
    local cf_list="" cf
    if [[ -n "${P_CONTROL_FILES:-}" ]]; then
        for cf in $P_CONTROL_FILES; do cf_list="${cf_list:+${cf_list}, }'${cf}'"; done
        cf_sql="ALTER SYSTEM SET control_files = ${cf_list} SCOPE=SPFILE;"
    fi
    ll_sql=""
    if [[ "$SCN_NET" == "scratch" ]]; then
        ll_sql="ALTER SYSTEM SET local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=${host})(PORT=${SCN_PORT}))' SCOPE=BOTH;"
    fi
    local omf_log_sql=""
    if [[ "$P_STORAGE" == "omf" ]]; then
        [[ -n "${P_OMF_ONLINE_LOG_DEST_1:-}" ]] && omf_log_sql="ALTER SYSTEM SET db_create_online_log_dest_1 = '${P_OMF_ONLINE_LOG_DEST_1}' SCOPE=BOTH;"
        [[ -n "${P_OMF_ONLINE_LOG_DEST_2:-}" ]] && omf_log_sql="${omf_log_sql}
ALTER SYSTEM SET db_create_online_log_dest_2 = '${P_OMF_ONLINE_LOG_DEST_2}' SCOPE=BOTH;"
    else
        omf_log_sql=""
        reset_sql="${reset_sql}
ALTER SYSTEM RESET db_create_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_1 SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_2 SCOPE=SPFILE;"
    fi
    local want_lm="ARCHIVELOG" want_fl="YES" want_fb="NO"
    [[ "$P_ARCHIVELOG" == "no" ]] && want_lm="NOARCHIVELOG"
    [[ "$P_FORCE_LOGGING" == "no" ]] && want_fl="NO"
    [[ "$P_FLASHBACK" == "yes" ]] && want_fb="YES"
    local archivelog_sql="DECLARE
  v_lm VARCHAR2(20); v_fl VARCHAR2(10); v_fb VARCHAR2(20);
BEGIN
  SELECT log_mode, force_logging, flashback_on INTO v_lm, v_fl, v_fb FROM v\$database;
  IF v_lm <> '${want_lm}' THEN EXECUTE IMMEDIATE 'ALTER DATABASE ${want_lm}'; END IF;
  IF v_fl <> '${want_fl}' THEN EXECUTE IMMEDIATE 'ALTER DATABASE $( [[ "$want_fl" == "YES" ]] && echo FORCE || echo "NO FORCE" ) LOGGING'; END IF;
  IF v_fb <> '${want_fb}' THEN EXECUTE IMMEDIATE 'ALTER DATABASE FLASHBACK $( [[ "$want_fb" == "YES" ]] && echo ON || echo OFF )'; END IF;
END;
/"
    local fl_sql="" fb_sql=""

    cat <<REMOTE
set -e
cd /tmp
# control-file copies must exist before the instance starts with the new list
CF_CURRENT=\$(sqlplus -s / as sysdba <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT name FROM v\$controlfile WHERE ROWNUM = 1;
EXIT;
SQLEOF
)
CF_CURRENT=\$(echo "\$CF_CURRENT" | tr -d '[:space:]')
# RESETs first and tolerant: DBCA may not have put the entry in the spfile
# at all (ORA-32010), which is exactly the state we want.
sqlplus -s / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
SET ECHO ON
${reset_sql}
EXIT;
SQLEOF
sqlplus -s / as sysdba <<'SQLEOF'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON
${fra_sql}
${pw_sql}
${conv_sql}
${brk_sql}
${cf_sql}
${omf_log_sql}
SHUTDOWN IMMEDIATE;
EXIT;
SQLEOF
$( for cf in ${P_CONTROL_FILES:-}; do printf 'cp -p "$CF_CURRENT" %s\n' "$(shq "$cf")"; done )
sqlplus -s / as sysdba <<'SQLEOF'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON
STARTUP MOUNT;
${archivelog_sql}
${fl_sql}
${fb_sql}
ALTER DATABASE OPEN;
ALTER SYSTEM SET log_archive_dest_1 = '${arch_dest}' SCOPE=BOTH;
${ll_sql}
ALTER SYSTEM REGISTER;
EXIT;
SQLEOF
sqlplus -s / as sysdba <<'SQLEOF'
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON
$(_sql_datafile_layout)
$(_sql_redo_rebuild)
$(_sql_srls)
$(_sql_pdbs)
$(_sql_services)
$(_sql_seed)
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
SQLEOF
# remove the redo files we dropped (DROP LOGFILE keeps non-OMF OS files)
MEMBERS=\$(sqlplus -s / as sysdba <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400
SELECT member FROM v\$logfile;
EXIT;
SQLEOF
)
for d in $(for d in ${P_REDO_DIRS:-} ${P_DATA_DIRS:-}; do shq "$d"; printf ' '; done); do
    [[ -d "\$d" ]] || continue
    for f in "\$d"/redo*.log; do
        [[ -f "\$f" ]] || continue
        printf '%s\n' "\$MEMBERS" | grep -qxF "\$f" || rm -f "\$f"
    done
done
$( [[ -n "${P_POST_SQL:-}" ]] && printf 'sqlplus -s / as sysdba @%s\n' "$(shq "${REPO_DIR}/tests/e2e/scenarios/primaries/${P_POST_SQL}")" )
echo __RESHAPE_OK__
REMOTE
}

provision_reshape() {
    log_section "Reshaping ${P_DB_NAME} to profile ${P_ID}"
    local script="${SCN_LOG}/provision/reshape.sh" out
    _remote_reshape > "$script"
    out=$(ssh_script "PRIMARY" "$script" | tee "${SCN_LOG}/provision/reshape.log")
    if printf '%s' "$out" | grep -q __RESHAPE_OK__; then
        log_pass "Primary reshaped"
    else
        log_fail "Reshape failed"
        printf '%s\n' "$out" | grep -E 'ORA-|ERROR|SP2-|PLS-' | grep -v 'ORA-32010' | head -10 | while IFS= read -r l; do log_info "  $l"; done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Shape verification: the profile must have taken, or the scenario tests
# something else than it claims
# ---------------------------------------------------------------------------
_shape_query() {
    cat <<'SQL'
SELECT 'LOG_MODE=' || log_mode || '|FORCE_LOGGING=' || force_logging || '|FLASHBACK=' || flashback_on || '|CDB=' || cdb || '|UNIQUE=' || UPPER(db_unique_name) || '|NAME=' || UPPER(name) FROM v$database;
SELECT 'PWFILE=' || value FROM v$parameter WHERE name = 'remote_login_passwordfile';
SELECT 'DOMAIN=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_domain';
SELECT 'FRA=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_recovery_file_dest';
SELECT 'OMF=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_create_file_dest';
SELECT 'OLD1=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_create_online_log_dest_1';
SELECT 'OLD2=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_create_online_log_dest_2';
SELECT 'ARCH=' || NVL(value, '-') FROM v$parameter WHERE name = 'log_archive_dest_1';
SELECT 'BRK1=' || NVL(value, '-') FROM v$parameter WHERE name = 'dg_broker_config_file1';
SELECT 'LCONV=' || NVL(value, '-') FROM v$parameter WHERE name = 'log_file_name_convert';
SELECT 'DCONV=' || NVL(value, '-') FROM v$parameter WHERE name = 'db_file_name_convert';
SELECT 'DATADIR=' || SUBSTR(name, 1, INSTR(name, '/', -1) - 1) FROM (SELECT DISTINCT name FROM v$datafile WHERE con_id IN (0,1,3,4,5,6));
SELECT 'REDODIR=' || SUBSTR(member, 1, INSTR(member, '/', -1) - 1) FROM (SELECT DISTINCT member FROM v$logfile WHERE type = 'ONLINE');
SELECT 'CTLDIR=' || SUBSTR(name, 1, INSTR(name, '/', -1) - 1) FROM (SELECT DISTINCT name FROM v$controlfile);
SELECT 'TEMPDIR=' || SUBSTR(name, 1, INSTR(name, '/', -1) - 1) FROM (SELECT DISTINCT name FROM v$tempfile WHERE con_id IN (0,1));
SELECT 'REDO_GROUPS=' || COUNT(*) || '|REDO_MB=' || MIN(bytes)/1048576 || '|MEMBERS=' || MIN(members) FROM v$log;
SELECT 'SRL_COUNT=' || COUNT(*) || '|SRL_MB=' || NVL(MIN(bytes)/1048576, 0) || '|SRL_THREAD0=' || SUM(CASE WHEN thread# = 0 THEN 1 ELSE 0 END) FROM v$standby_log;
SELECT 'PDB=' || name || ':' || open_mode FROM v$pdbs WHERE name <> 'PDB$SEED';
SELECT 'SVC=' || CASE WHEN s.con_id = 0 THEN 'ROOT' ELSE NVL((SELECT name FROM v$containers c WHERE c.con_id = s.con_id), 'ROOT') END || ':' || s.name FROM v$active_services s WHERE s.name NOT LIKE 'SYS$%' AND s.name NOT LIKE '%XDB' AND s.name NOT LIKE '%_CFG' AND s.name NOT LIKE '%_DGMGRL' AND UPPER(s.name) NOT IN (SELECT UPPER(name) FROM v$database UNION SELECT UPPER(db_unique_name) FROM v$database UNION SELECT UPPER(name) FROM v$containers UNION SELECT UPPER(d.name || '.' || NVL(p.value, '-')) FROM v$database d, v$parameter p WHERE p.name = 'db_domain' UNION SELECT UPPER(c.name || '.' || NVL(p.value, '-')) FROM v$containers c, v$parameter p WHERE p.name = 'db_domain');
SELECT 'MARKS=' || COUNT(*) FROM MARK_SCHEMA_PLACEHOLDER.marks;
SQL
}

verify_shape() {
    log_section "Verifying the primary matches profile ${P_ID}"
    local out ok=1
    out=$(ssh_sql_raw "PRIMARY" "$(_shape_query | sed "s/MARK_SCHEMA_PLACEHOLDER/${MARK_USER}/")")
    printf '%s\n' "$out" > "${SCN_LOG}/provision/shape.txt"
    _has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
    _expect() { # value label
        if _has "$1"; then log_pass "shape: $2"; else log_fail "shape: $2 (wanted '$1')"; ok=0; fi
    }
    _expect "LOG_MODE=$( [[ "$P_ARCHIVELOG" == "yes" ]] && echo ARCHIVELOG || echo NOARCHIVELOG )" "archive mode"
    _expect "FORCE_LOGGING=$( [[ "$P_FORCE_LOGGING" == "yes" ]] && echo YES || echo NO )" "force logging"
    _expect "FLASHBACK=$( [[ "$P_FLASHBACK" == "yes" ]] && echo YES || echo NO )" "flashback"
    _expect "CDB=$( [[ "$P_CDB" == "yes" ]] && echo YES || echo NO )" "CDB"
    _expect "UNIQUE=$(upper "$P_DB_UNIQUE_NAME")" "db_unique_name"
    _expect "PWFILE=$(upper "$P_PWFILE")" "password file mode"
    [[ -n "${P_DB_DOMAIN:-}" ]] && _expect "DOMAIN=${P_DB_DOMAIN}" "db_domain"
    if [[ -n "${P_FRA_DIR:-}" ]]; then _expect "FRA=${P_FRA_DIR}" "FRA"; else _expect "FRA=-" "no FRA"; fi
    if [[ "$P_STORAGE" == "omf" ]]; then
        _expect "OMF=${P_OMF_FILE_DEST}" "db_create_file_dest"
        [[ -n "${P_OMF_ONLINE_LOG_DEST_1:-}" ]] && _expect "OLD1=${P_OMF_ONLINE_LOG_DEST_1}" "db_create_online_log_dest_1"
        [[ -n "${P_OMF_ONLINE_LOG_DEST_2:-}" ]] && _expect "OLD2=${P_OMF_ONLINE_LOG_DEST_2}" "db_create_online_log_dest_2"
    else
        _expect "OMF=-" "no OMF"
        local d
        for d in $P_DATA_DIRS; do _expect "DATADIR=${d}" "datafiles in ${d}"; done
        for d in $P_REDO_DIRS; do _expect "REDODIR=${d}" "redo in ${d}"; done
        [[ -n "${P_TEMP_DIR:-}" ]] && _expect "TEMPDIR=${P_TEMP_DIR}" "temp in ${P_TEMP_DIR}"
        local cf; for cf in ${P_CONTROL_FILES:-}; do _expect "CTLDIR=$(dirname "$cf")" "control file in $(dirname "$cf")"; done
        # nothing may remain under a directory the profile did not ask for
        local extra; extra=$(printf '%s\n' "$out" | grep '^DATADIR=' | sed 's/^DATADIR=//' | while IFS= read -r dd; do
            local hit=0 x; for x in $P_DATA_DIRS; do [[ "$dd" == "$x" || "$dd" == "$x"/* ]] && hit=1; done; [[ $hit -eq 0 ]] && printf '%s\n' "$dd"; done)
        if [[ -n "$extra" ]]; then log_fail "shape: datafiles outside the profile's directories: $(printf '%s' "$extra" | tr '\n' ' ')"; ok=0; else log_pass "shape: no datafile outside the profile's directories"; fi
    fi
    if [[ "${P_ARCHIVE_DEST:-}" == "FRA" ]]; then _expect "ARCH=LOCATION=USE_DB_RECOVERY_FILE_DEST" "archiving into the FRA"; else _expect "ARCH=LOCATION=${P_ARCHIVE_DEST}" "archive destination"; fi
    [[ -n "${P_BROKER_FILE_DIR:-}" ]] && _expect "BRK1=${P_BROKER_FILE_DIR}/" "broker config file dir"
    case "${P_PRESET_CONVERT:-}" in
        log|both) _expect "LCONV=/nonexistent" "log_file_name_convert preset" ;;
        *) _expect "LCONV=-" "no log_file_name_convert" ;;
    esac
    case "${P_PRESET_CONVERT:-}" in
        db|both) _expect "DCONV=/nonexistent" "db_file_name_convert preset" ;;
        *) _expect "DCONV=-" "no db_file_name_convert" ;;
    esac
    _expect "REDO_GROUPS=${P_REDO_GROUPS}|REDO_MB=${P_REDO_SIZE_MB}|MEMBERS=$( [[ "$P_STORAGE" == "omf" ]] && echo 1 || echo "$(set -- $P_REDO_DIRS; echo $#)" )" "redo groups/size/members"
    case "$P_PRE_SRL" in
        none)       _expect "SRL_COUNT=0|" "no pre-existing SRLs" ;;
        ok)         _expect "SRL_COUNT=$(( P_REDO_GROUPS + 1 ))|SRL_MB=${P_REDO_SIZE_MB}|" "pre-existing SRLs (adequate)" ;;
        undersized) _expect "SRL_COUNT=$(( P_REDO_GROUPS + 1 ))|SRL_MB=$(( P_REDO_SIZE_MB / 2 ))|" "pre-existing SRLs (undersized)" ;;
    esac
    [[ "$P_PRE_SRL" != "none" && "$P_PRE_SRL_THREAD" == "none" ]] && _expect "SRL_THREAD0=$(( P_REDO_GROUPS + 1 ))" "SRLs at THREAD#=0"
    local pdb; for pdb in ${P_PDBS:-}; do _expect "PDB=$(upper "$pdb"):READ WRITE" "PDB ${pdb} open"; done
    local spec cont svc
    for spec in ${P_SERVICES:-}; do
        if [[ "$spec" == *:* ]]; then cont=$(upper "${spec%%:*}"); svc="${spec#*:}"; else cont="ROOT"; svc="$spec"; fi
        [[ "$cont" == "CDB" || "$cont" == 'CDB$ROOT' ]] && cont='CDB$ROOT'
        [[ "$P_CDB" == "no" ]] && cont="ROOT"
        if _has "SVC=${cont}:${svc}" || _has "SVC=ROOT:${svc}"; then log_pass "shape: service ${svc} running (${cont})"; else log_fail "shape: service ${svc} not running (${cont})"; ok=0; fi
    done
    _expect "MARKS=0" "marker table present"
    [[ $ok -eq 1 ]]
}

# provision = network + DBCA; reshape = the post-SQL + shape verification.
# Split so a failed reshape can be re-run on the database DBCA already built
# (e2e.sh run --scenario X --from reshape) instead of paying for DBCA again.
provision_create() {
    mkdir -p "${SCN_LOG}/provision"
    log_phase "PROVISION: primary ${P_DB_NAME} from profile ${P_ID} for ${SCN_ID}"
    provision_net PRIMARY || return 1
    provision_net STANDBY || return 1
    ssh_cmd "PRIMARY" "mkdir -p $(shq "$SCN_WORK") && chmod 700 $(shq "$SCN_WORK")" >/dev/null
    ssh_cmd "STANDBY" "mkdir -p $(shq "$SCN_WORK") && chmod 700 $(shq "$SCN_WORK")" >/dev/null
    provision_db || return 1
}
provision_finish() {
    mkdir -p "${SCN_LOG}/provision"
    log_phase "RESHAPE: ${P_DB_NAME} to profile ${P_ID}"
    # --from reshape on a database that exists but is down: start it; on no
    # database at all: say so instead of a wall of ORA-01034
    local st; st=$(ssh_cmd PRIMARY "
if ps -eo args | grep -q '[o]ra_pmon_${P_SID}\$'; then echo UP
elif [[ -f \"\$ORACLE_HOME/dbs/spfile${P_SID}.ora\" ]]; then sqlplus -s / as sysdba <<'SQLEOF' >/dev/null 2>&1
STARTUP;
EXIT;
SQLEOF
ps -eo args | grep -q '[o]ra_pmon_${P_SID}\$' && echo STARTED || echo DEAD
else echo MISSING; fi")
    case "$st" in
        *UP*) ;;
        *STARTED*) log_info "instance ${P_SID} was down; started it" ;;
        *) log_fail "no database ${P_SID} on the primary (${st}); run without --from reshape to provision it"; return 1 ;;
    esac
    provision_reshape || return 1
    verify_shape || return 1
    log_pass "Primary ${P_DB_NAME} ready (${P_DESC:-})"
}
provision_scenario() { provision_create && provision_finish; }

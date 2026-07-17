#!/bin/bash
# ============================================================
# Unit test for the DB_FILE_NAME_CONVERT generation logic in
# primary/02_generate_standby_config.sh
# ============================================================
# Regression guard for:
#   1. Only the first primary datafile directory ends up in
#      DB_FILE_NAME_CONVERT when the primary has multiple distinct
#      directories.
#   2. The bash `local a="$1" b="$2" key="$a=>$b"` gotcha - $a/$b
#      are unset at the time `key` is evaluated, so every dedup
#      check sees the same empty key and collapses every pair.
#   3. Pair ORDERING - Oracle applies the FIRST prefix match, so a
#      shorter primary path (/u01/oradata) listed before a longer
#      overlapping one (/u01/oradata2) shadows it. Pairs must be
#      sorted by primary length DESCENDING and emitted with trailing
#      slashes so prefix matches are component-bounded.
#   4. SRL contradiction - PRIMARY_SRL_PATH == PRIMARY_REDO_PATH with
#      a differing STANDBY_SRL_PATH emits a warning (that standby SRL
#      directory is unreachable by any pair), not a silent pair.
#
# build_convert_pairs below is kept byte-identical to the copy in
# primary/02_generate_standby_config.sh so a regression in either
# copy fails this test.
# ============================================================

set +e

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "  PASS: $name"
            PASS=$((PASS + 1))
            ;;
        *)
            echo "  FAIL: $name"
            echo "    expected to contain: $needle"
            echo "    actual:              $haystack"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "  FAIL: $name"
            echo "    expected NOT to contain: $needle"
            echo "    actual:                  $haystack"
            FAIL=$((FAIL + 1))
            ;;
        *)
            echo "  PASS: $name"
            PASS=$((PASS + 1))
            ;;
    esac
}

# The script logs through log_warn (dg_functions.sh); capture the
# messages here so the SRL-contradiction and length warnings can be
# asserted on.
_WARNINGS=""
log_warn() { _WARNINGS="${_WARNINGS}$*
"; }

# Reset the SRL/redo globals build_convert_pairs reads, and the
# warning capture, before each scenario.
reset_globals() {
    PRIMARY_SRL_PATH=""
    STANDBY_SRL_PATH=""
    PRIMARY_REDO_PATH=""
    STANDBY_REDO_PATH=""
    _WARNINGS=""
}

# ------------------------------------------------------------
# build_convert_pairs lifted VERBATIM from
# primary/02_generate_standby_config.sh - do not edit here; edit the
# script and re-copy. assert_no_drift() below enforces that mechanically
# (this used to be a comment-only convention, so the copies could rot
# apart while every test still passed).
# ------------------------------------------------------------
build_convert_pairs() {
    local _pd_arr="$1"
    local _sd_arr="$2"
    local _pr_arr="$3"
    local _sr_arr="$4"
    local _seen_pairs=" "  # space-bounded list so we can test membership
    _cp_pri=()
    _cp_stby=()

    # Normalize both sides to exactly one trailing slash, dedup, and
    # collect into the parallel _cp_pri/_cp_stby arrays.
    # NOTE: separate `local` statements - declaring on one line as
    # `local a="$1" b="$2" key="...${a}...${b}..."` evaluates ${a}
    # and ${b} BEFORE local assigns them, so key would be empty and
    # the dedup membership check would collapse every pair into one.
    _collect_pair() {
        local primary="$1"
        local standby="$2"
        [[ -z "$primary" || -z "$standby" ]] && return 0
        # "${p%/}/" maps /a -> /a/, /a/ -> /a/, and / -> / unchanged.
        primary="${primary%/}/"
        standby="${standby%/}/"
        local key=" ${primary}=>${standby} "
        case "$_seen_pairs" in
            *"$key"*) return 0 ;;
        esac
        _seen_pairs="${_seen_pairs}${primary}=>${standby} "
        _cp_pri+=("$primary")
        _cp_stby+=("$standby")
    }

    # Walk two index-parallel arrays by NAME (eval indirection keeps
    # this bash 3.2 / AIX compatible - no namerefs).
    _collect_from_arrays() {
        local _pa="$1"
        local _sa="$2"
        local _k=0 _cnt _p _s
        eval "_cnt=\${#${_pa}[@]}"
        while [[ $_k -lt $_cnt ]]; do
            eval "_p=\${${_pa}[$_k]}"
            eval "_s=\${${_sa}[$_k]}"
            _collect_pair "$_p" "$_s"
            _k=$(( _k + 1 ))
        done
    }

    # Datafile pairs, then redo log pairs - one per distinct directory
    _collect_from_arrays "$_pd_arr" "$_sd_arr"
    _collect_from_arrays "$_pr_arr" "$_sr_arr"

    # Detect the data/redo collision: the PRIMARY keeps redo logs in the
    # SAME directory as datafiles, but the STANDBY splits them into two.
    # Both pairs are emitted and share an identical primary path, so the
    # length sort below cannot separate them and Oracle's first-prefix
    # match always picks the earlier one (datafiles). Redo logs then land
    # in the standby DATA directory and the split redo directory is never
    # used - functional, but not what the operator asked for, and silent
    # until someone looks at V$LOGFILE on the standby post-clone.
    #
    # A convert pair remaps a primary FILENAME; when ORLs and datafiles
    # share one primary directory nothing distinguishes them, so no pair
    # can send them to different standby directories. Warn rather than
    # "fix": splitting them requires a distinct PRIMARY redo directory,
    # which is a primary-side change only the operator can make.
    _warn_data_redo_collision() {
        local _pa="$1" _sa="$2" _ra="$3" _rsa="$4"
        local _ri=0 _rn _di _dn _rp _rs _dp _ds
        eval "_rn=\${#${_ra}[@]}"
        eval "_dn=\${#${_pa}[@]}"
        while [[ $_ri -lt $_rn ]]; do
            eval "_rp=\${${_ra}[$_ri]}"
            eval "_rs=\${${_rsa}[$_ri]}"
            if [[ -n "$_rp" && -n "$_rs" ]]; then
                _rp="${_rp%/}/"
                _rs="${_rs%/}/"
                _di=0
                while [[ $_di -lt $_dn ]]; do
                    eval "_dp=\${${_pa}[$_di]}"
                    eval "_ds=\${${_sa}[$_di]}"
                    if [[ -n "$_dp" && -n "$_ds" ]]; then
                        _dp="${_dp%/}/"
                        _ds="${_ds%/}/"
                        if [[ "$_rp" == "$_dp" && "$_rs" != "$_ds" ]]; then
                            log_warn "Data/redo path collision: the primary keeps datafiles AND redo logs in"
                            log_warn "  ${_rp}"
                            log_warn "  but the standby splits them (data -> ${_ds}, redo -> ${_rs})."
                            log_warn "  Convert pairs remap primary filenames, and nothing distinguishes an ORL"
                            log_warn "  from a datafile when both share one primary directory - so both pairs"
                            log_warn "  share the primary path '${_rp}' and Oracle's first-prefix match takes the"
                            log_warn "  datafile pair. Redo logs WILL be created under ${_ds} on the standby;"
                            log_warn "  ${_rs} will stay unused."
                            log_warn "  To split redo on the standby, give the PRIMARY a distinct redo directory"
                            log_warn "  as well, then re-run this script."
                        fi
                    fi
                    _di=$(( _di + 1 ))
                done
            fi
            _ri=$(( _ri + 1 ))
        done
    }
    _warn_data_redo_collision "$_pd_arr" "$_sd_arr" "$_pr_arr" "$_sr_arr"

    # Separate SRL pair when configured. When the PRIMARY side is NOT
    # separated (PRIMARY_SRL_PATH == PRIMARY_REDO_PATH) no SRL pair is
    # emitted - so a standby-only separation is unreachable: no pair
    # maps anything INTO that standby SRL directory, and SRLs will be
    # created under STANDBY_REDO_PATH via the ordinary redo pair.
    # Detect and warn about that contradiction instead of silently
    # shipping a directory that never gets used.
    if [[ -n "${PRIMARY_SRL_PATH:-}" && "${PRIMARY_SRL_PATH}" != "${PRIMARY_REDO_PATH:-}" ]]; then
        _collect_pair "$PRIMARY_SRL_PATH" "${STANDBY_SRL_PATH:-}"
    elif [[ -n "${STANDBY_SRL_PATH:-}" && "${STANDBY_SRL_PATH}" != "${STANDBY_REDO_PATH:-}" ]]; then
        log_warn "SRL path contradiction: PRIMARY_SRL_PATH equals PRIMARY_REDO_PATH, but"
        log_warn "  STANDBY_SRL_PATH (${STANDBY_SRL_PATH}) differs from STANDBY_REDO_PATH (${STANDBY_REDO_PATH:-})."
        log_warn "  Convert pairs remap primary filenames, and no primary SRL filename is"
        log_warn "  distinguishable from an ORL filename when both share one directory - so"
        log_warn "  no pair can target the standby SRL directory. SRLs will be created under"
        log_warn "  ${STANDBY_REDO_PATH:-} on the standby. To separate SRLs on the standby,"
        log_warn "  set PRIMARY_SRL_PATH to a distinct primary directory as well."
    fi

    # Stable insertion sort by primary-path length DESCENDING (see the
    # ordering rationale in the function header). Pair counts are tiny
    # (a handful of directories), so O(n^2) in pure bash is fine.
    local _n=${#_cp_pri[@]}
    local _i=1 _j _kp _ks
    while [[ $_i -lt $_n ]]; do
        _kp="${_cp_pri[$_i]}"
        _ks="${_cp_stby[$_i]}"
        _j=$(( _i - 1 ))
        while [[ $_j -ge 0 && ${#_cp_pri[$_j]} -lt ${#_kp} ]]; do
            _cp_pri[$(( _j + 1 ))]="${_cp_pri[$_j]}"
            _cp_stby[$(( _j + 1 ))]="${_cp_stby[$_j]}"
            _j=$(( _j - 1 ))
        done
        _cp_pri[$(( _j + 1 ))]="$_kp"
        _cp_stby[$(( _j + 1 ))]="$_ks"
        _i=$(( _i + 1 ))
    done

    # Assemble the quoted, comma-separated convert string
    local _pairs=""
    _i=0
    while [[ $_i -lt $_n ]]; do
        if [[ -z "$_pairs" ]]; then
            _pairs="'${_cp_pri[$_i]}','${_cp_stby[$_i]}'"
        else
            _pairs="${_pairs},'${_cp_pri[$_i]}','${_cp_stby[$_i]}'"
        fi
        _i=$(( _i + 1 ))
    done
    DB_FILE_NAME_CONVERT="$_pairs"
    LOG_FILE_NAME_CONVERT="$_pairs"

    if [[ $_n -gt 20 || ${#_pairs} -gt 2000 ]]; then
        log_warn "DB_FILE_NAME_CONVERT holds ${_n} pairs (${#_pairs} chars). Very long"
        log_warn "  convert strings are fragile (parameter length limits, easy to miss a"
        log_warn "  directory). For many-PDB CDBs consider OMF mode instead (storage mode"
        log_warn "  2 at step 2: db_create_file_dest, no convert strings needed)."
    fi
}

echo "Test 1: single data path + redo on a distinct directory"
reset_globals
PRIMARY_DATA=("/u01/app/oracle/oradata/DGNONC")
STANDBY_DATA=("/u01/app/oracle/oradata/DGNONC_S")
PRIMARY_REDO=("/u02/redo/DGNONC")
STANDBY_REDO=("/u02/redo/DGNONC_S")
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "single data + redo on a separate mount = two pairs, longest first, trailing slashes" \
    "'/u01/app/oracle/oradata/DGNONC/','/u01/app/oracle/oradata/DGNONC_S/','/u02/redo/DGNONC/','/u02/redo/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 2: three distinct data paths (equal length keeps input order)"
reset_globals
PRIMARY_DATA=(
    "/u01/app/oracle/oradata/DGNONC"
    "/u02/app/oracle/oradata/DGNONC"
    "/u03/app/oracle/oradata/DGNONC"
)
STANDBY_DATA=(
    "/u01/app/oracle/oradata/DGNONC_S"
    "/u02/app/oracle/oradata/DGNONC_S"
    "/u03/app/oracle/oradata/DGNONC_S"
)
PRIMARY_REDO=()
STANDBY_REDO=()
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "three data paths emit three pairs, stable order" \
    "'/u01/app/oracle/oradata/DGNONC/','/u01/app/oracle/oradata/DGNONC_S/','/u02/app/oracle/oradata/DGNONC/','/u02/app/oracle/oradata/DGNONC_S/','/u03/app/oracle/oradata/DGNONC/','/u03/app/oracle/oradata/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 3: dedup drops exact duplicate pair (incl. trailing-slash variant)"
reset_globals
PRIMARY_DATA=(
    "/u01/oradata/DGNONC"
    "/u01/oradata/DGNONC"
    "/u01/oradata/DGNONC/"
)
STANDBY_DATA=(
    "/u01/oradata/DGNONC_S"
    "/u01/oradata/DGNONC_S"
    "/u01/oradata/DGNONC_S/"
)
PRIMARY_REDO=()
STANDBY_REDO=()
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "duplicate pairs collapsed to one" \
    "'/u01/oradata/DGNONC/','/u01/oradata/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 4: data + redo where one redo dir coincides with a data dir"
# The first redo directory names the same directory as the first data
# directory; normalization makes the two byte-identical, so the dedup
# collapses them and only the genuinely new redo directory
# (/u04/redo/DGNONC) adds a pair. Data dirs (longer) sort first.
reset_globals
PRIMARY_DATA=(
    "/u01/oradata/DGNONC"
    "/u02/oradata/DGNONC"
)
STANDBY_DATA=(
    "/u01/oradata/DGNONC_S"
    "/u02/oradata/DGNONC_S"
)
PRIMARY_REDO=(
    "/u01/oradata/DGNONC"
    "/u04/redo/DGNONC"
)
STANDBY_REDO=(
    "/u01/oradata/DGNONC_S"
    "/u04/redo/DGNONC_S"
)
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "data (2) + redo (1 collapses, 1 new) = 3 pairs" \
    "'/u01/oradata/DGNONC/','/u01/oradata/DGNONC_S/','/u02/oradata/DGNONC/','/u02/oradata/DGNONC_S/','/u04/redo/DGNONC/','/u04/redo/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 5: prefix overlap - /u01/oradata must NOT shadow /u01/oradata2"
# Oracle applies the FIRST matching pair. If /u01/oradata came first,
# every file under /u01/oradata2 would be mis-remapped through it
# (prefix match). The longer primary path must sort first, and the
# trailing slashes keep /u01/oradata/ from prefix-matching
# /u01/oradata2/... at all.
reset_globals
PRIMARY_DATA=(
    "/u01/oradata"
    "/u01/oradata2"
)
STANDBY_DATA=(
    "/stby/data"
    "/stby/data2"
)
PRIMARY_REDO=()
STANDBY_REDO=()
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "longer overlapping primary path sorts first" \
    "'/u01/oradata2/','/stby/data2/','/u01/oradata/','/stby/data/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 6: separate SRL directory adds its own pair"
reset_globals
PRIMARY_REDO_PATH="/u02/redo/DGNONC"
STANDBY_REDO_PATH="/u02/redo/DGNONC_S"
PRIMARY_SRL_PATH="/u05/srl/DGNONC"
STANDBY_SRL_PATH="/u05/srl/DGNONC_S"
PRIMARY_DATA=("/u01/oradata/DGNONC")
STANDBY_DATA=("/u01/oradata/DGNONC_S")
PRIMARY_REDO=("/u02/redo/DGNONC")
STANDBY_REDO=("/u02/redo/DGNONC_S")
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "data + redo + SRL = 3 pairs" \
    "'/u01/oradata/DGNONC/','/u01/oradata/DGNONC_S/','/u02/redo/DGNONC/','/u02/redo/DGNONC_S/','/u05/srl/DGNONC/','/u05/srl/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"
assert_eq "no warning for a consistent SRL separation" "" "$_WARNINGS"

echo "Test 7: SRL contradiction (standby-only separation) warns, adds no pair"
reset_globals
PRIMARY_REDO_PATH="/u02/redo/DGNONC"
STANDBY_REDO_PATH="/u02/redo/DGNONC_S"
PRIMARY_SRL_PATH="/u02/redo/DGNONC"       # same as primary ORL dir
STANDBY_SRL_PATH="/u09/srl/DGNONC_S"      # differs on the standby
PRIMARY_DATA=("/u01/oradata/DGNONC")
STANDBY_DATA=("/u01/oradata/DGNONC_S")
PRIMARY_REDO=("/u02/redo/DGNONC")
STANDBY_REDO=("/u02/redo/DGNONC_S")
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_eq "no pair references the unreachable standby SRL dir" \
    "'/u01/oradata/DGNONC/','/u01/oradata/DGNONC_S/','/u02/redo/DGNONC/','/u02/redo/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"
assert_contains "warning explains SRLs land under STANDBY_REDO_PATH" \
    "SRL path contradiction" "$_WARNINGS"

echo "Test 8: >20 pairs triggers the length/fragility warning"
reset_globals
PRIMARY_DATA=()
STANDBY_DATA=()
PRIMARY_REDO=()
STANDBY_REDO=()
_i=1
while [[ $_i -le 21 ]]; do
    PRIMARY_DATA+=("/u${_i}/oradata/DGNONC")
    STANDBY_DATA+=("/u${_i}/oradata/DGNONC_S")
    _i=$((_i + 1))
done
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_contains "21 pairs warns and points at OMF mode" \
    "consider OMF mode" "$_WARNINGS"

# ------------------------------------------------------------
# Data/redo collision: primary keeps datafiles AND redo in one
# directory, standby splits them. No pair can target the standby redo
# dir (nothing distinguishes an ORL from a datafile on the primary
# side), so the datafile pair wins first-prefix-match and redo lands in
# the standby DATA dir. Must warn, not ship the split silently.
# ------------------------------------------------------------
echo "Test 9: data/redo collision (primary shares a dir, standby splits)"
# The primary keeps datafiles AND redo in one directory while the standby
# splits them. Both pairs share the primary path, so the length sort
# cannot separate them and Oracle takes the datafile pair - redo lands in
# the standby DATA dir and the split redo dir is never used. Must warn.
reset_globals
PRIMARY_DATA=("/u01/oradata/DGNONC")
STANDBY_DATA=("/u01/stby/data/DGNONC_S")
PRIMARY_REDO=("/u01/oradata/DGNONC")        # same dir as datafiles
STANDBY_REDO=("/u01/stby/redo/DGNONC_S")    # standby splits them out
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_contains "collision warns" \
    "Data/redo path collision" "$_WARNINGS"
assert_contains "collision warning names the standby redo dir that stays unused" \
    "/u01/stby/redo/DGNONC_S/ will stay unused" "$_WARNINGS"
assert_eq "datafile pair is emitted first (Oracle takes the first prefix match)" \
    "'/u01/oradata/DGNONC/','/u01/stby/data/DGNONC_S/','/u01/oradata/DGNONC/','/u01/stby/redo/DGNONC_S/'" \
    "$DB_FILE_NAME_CONVERT"

echo "Test 10: no collision warning when the standby also shares the dir"
# Same shared primary dir, but the standby keeps them together too - the
# dedup collapses the pairs and there is nothing to warn about.
reset_globals
PRIMARY_DATA=("/u01/oradata/DGNONC")
STANDBY_DATA=("/u01/stby/data/DGNONC_S")
PRIMARY_REDO=("/u01/oradata/DGNONC")
STANDBY_REDO=("/u01/stby/data/DGNONC_S")    # same target - consistent
build_convert_pairs PRIMARY_DATA STANDBY_DATA PRIMARY_REDO STANDBY_REDO
assert_not_contains "identical standby dirs stay quiet" \
    "Data/redo path collision" "$_WARNINGS"

# ------------------------------------------------------------
# Drift guard: the build_convert_pairs copy above must stay
# byte-identical to the one in primary/02_generate_standby_config.sh,
# or these tests validate code that no longer ships.
# ------------------------------------------------------------
echo "Test 11: build_convert_pairs copy has not drifted from the script"
_SCRIPT="$(dirname "$0")/../primary/02_generate_standby_config.sh"
if [[ ! -f "$_SCRIPT" ]]; then
    echo "  FAIL: cannot find $_SCRIPT"
    FAIL=$((FAIL + 1))
else
    # Range: the function header through its first column-0 '}'. Nested
    # helpers are indented, so they cannot terminate the range early.
    _TMP_A="${TMPDIR:-/tmp}/bcp_script.$$"
    _TMP_B="${TMPDIR:-/tmp}/bcp_test.$$"
    awk '/^build_convert_pairs\(\) \{/,/^\}$/' "$_SCRIPT" > "$_TMP_A"
    awk '/^build_convert_pairs\(\) \{/,/^\}$/' "$0"       > "$_TMP_B"
    if [[ ! -s "$_TMP_A" ]]; then
        echo "  FAIL: could not extract build_convert_pairs from the script"
        FAIL=$((FAIL + 1))
    elif diff -u "$_TMP_A" "$_TMP_B" > /dev/null 2>&1; then
        echo "  PASS: copies are byte-identical"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: build_convert_pairs has drifted from $_SCRIPT"
        echo "        re-copy the function into this test (script is the source of truth):"
        diff -u "$_TMP_A" "$_TMP_B" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
    rm -f "$_TMP_A" "$_TMP_B"
fi

echo ""
echo "============================================================"
echo "PASSED: $PASS  FAILED: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

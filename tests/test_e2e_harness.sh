#!/usr/bin/env bash
# =============================================================================
# tests/test_e2e_harness.sh - offline tests of the scenario E2E harness
# =============================================================================
# No lab needed. Covers:
#   1. lib/answer.py: pattern answers, once-rules, secret masking, context
#      (multi-line) rules, capture-group answers, unanswered prompt (97),
#      forbidden prompt (96), child exit status, [prompt] records
#   2. bash -n on e2e.sh and every lib/, checks/, proofs/ script
#   3. lib/scenario.sh: every catalog scenario loads against a fake config,
#      placeholders expand, S_NEEDS is derived, expected keys are present
#   4. lib/drive.sh: rule composition and @VAR@ expansion, secret masking
#   5. build.sh _step2_scenario_rules + answer.py against a fake review table
#      (the backreference mechanism that picks a row by its text)
#   6. lib/doctor.sh: doctor_unmet against synthetic capabilities
# Requires python3 (as the lab does).
# =============================================================================
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/.." && pwd)"
E2E="${REPO}/tests/e2e"
PASS=0; FAIL=0
pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

TMP=$(mktemp -d 2>/dev/null || { d="/tmp/e2e_harness_$$"; mkdir -p "$d" && echo "$d"; })
trap 'rm -rf "$TMP"' EXIT
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# ---------------------------------------------------------------------------
echo "1. answer.py"
# ---------------------------------------------------------------------------
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
printf '\033[0;34mNFS Share\033[0m\n'
printf "Press Enter to use this path, or type a different path: "; read -r a; echo "nfs=[$a]"
printf '\033[1;33mEnter SYS password for the local primary database\033[0m: ' >&2; stty -echo 2>/dev/null; read -r pw; stty echo 2>/dev/null; echo; echo "pwlen=${#pw}"
printf "Standby DB_UNIQUE_NAME: "; read -r n; echo "name=[$n]"
for i in 1 2 3; do echo "Derived mappings:"; echo "  1) [data] /a -> /b"; printf "Accept all mappings [Enter], or enter a number to edit: "; read -r x; echo "sel=[$x]"; [[ -z "$x" ]] && break; printf "New standby data directory for '/a' [/b]: "; read -r y; echo "new=[$y]"; done
printf '\033[1;33mContinue anyway?\033[0m\n'; printf "Do you want to proceed? [y/N]: "; read -r c; echo "cont=[$c]"
printf '\033[1;33mPlease review the configuration above.\033[0m\n'; printf "Do you want to proceed? [y/N]: "; read -r c; echo "review=[$c]"
echo "working..."; sleep 1; echo "done"
exit 3
EOF
chmod +x "$TMP/fake.sh"
printf '%s\n' \
 'Press Enter to use this path, or type a different path:	' \
 'Enter SYS password[^:\n]*:	s3cret	secret' \
 'Standby DB_UNIQUE_NAME:	dgtest_s' \
 'Accept all mappings \[Enter\], or enter a number to edit:	1	once' \
 "New standby data directory for '/a' \[/b\]:	/c" \
 'Accept all mappings \[Enter\], or enter a number to edit:	' \
 'Continue anyway\?\nDo you want to proceed\? \[y/N\]:	n' \
 'Do you want to proceed\? \[y/N\]:	y' > "$TMP/rules.txt"
python3 "$E2E/lib/answer.py" --rules "$TMP/rules.txt" --log "$TMP/run.log" --grace 3 -- "$TMP/fake.sh" > "$TMP/out.txt" 2> "$TMP/err.txt"; rc=$?
out=$(tr -d '\r' < "$TMP/out.txt")
check "child exit status propagated (3)" '[[ $rc -eq 3 ]]'
check "Enter answers the NFS prompt" 'grep -q "nfs=\[\]" <<< "$out"'
check "secret password delivered (length 6)" 'grep -q "pwlen=6" <<< "$out"'
check "pattern answer by text" 'grep -q "name=\[dgtest_s\]" <<< "$out"'
check "once-rule sequence: 1 then Enter" 'grep -q "sel=\[1\]" <<< "$out" && grep -q "new=\[/c\]" <<< "$out" && grep -q "sel=\[\]" <<< "$out"'
check "context rule outranks the generic yes" 'grep -q "cont=\[n\]" <<< "$out" && grep -q "review=\[y\]" <<< "$out"'
check "secret never written to the log" '! grep -aq s3cret "$TMP/run.log"'
check "[prompt] records on their own lines" 'grep -aq "^\[prompt\] Standby DB_UNIQUE_NAME: => dgtest_s" "$TMP/run.log" && grep -aq "^\[prompt\] Enter SYS password.*=> \*\*\*" "$TMP/run.log"'
check "8 prompts answered" 'grep -aq "prompts answered: 8" "$TMP/run.log"'

cat > "$TMP/fake2.sh" <<'EOF'
#!/usr/bin/env bash
printf "Standby DB_UNIQUE_NAME: "; read -r n; echo "name=[$n]"
printf "Some unforeseen question? [y/N]: "; read -r x; echo "x=[$x]"
echo never
EOF
chmod +x "$TMP/fake2.sh"
python3 "$E2E/lib/answer.py" --rules "$TMP/rules.txt" --log "$TMP/run2.log" --grace 2 -- "$TMP/fake2.sh" > "$TMP/out2.txt" 2> "$TMP/err2.txt"; rc=$?
check "unanswered prompt -> exit 97" '[[ $rc -eq 97 ]]'
check "unanswered prompt named on stderr" 'grep -q "UNANSWERED PROMPT: Some unforeseen question" "$TMP/err2.txt"'
check "child killed (never reached the end)" '! grep -aq never "$TMP/out2.txt"'
printf 'Some unforeseen question\\? \\[y/N\\]:\tn\tfail\n' > "$TMP/rules3.txt"; cat "$TMP/rules.txt" >> "$TMP/rules3.txt"
python3 "$E2E/lib/answer.py" --rules "$TMP/rules3.txt" --log "$TMP/run3.log" --grace 2 -- "$TMP/fake2.sh" > "$TMP/out3.txt" 2> "$TMP/err3.txt"; rc=$?
check "forbidden prompt -> exit 96 after answering it" '[[ $rc -eq 96 ]] && grep -aq "never" "$TMP/out3.txt"'
check "forbidden prompt recorded" 'grep -aq "(FORBIDDEN)" "$TMP/run3.log"'

# capture groups: answer the number of the row whose text matches
cat > "$TMP/fake3.sh" <<'EOF'
#!/usr/bin/env bash
for round in 1 2; do
  echo "Derived primary -> standby directory mappings:"
  echo "   1) [data] /u01/app/oracle/e2e/oradata/DGSPR -> /u01/app/oracle/e2e/oradata/DGSPR_S"
  echo "   2) [data] /home/oracle/e2e/oradata2/DGSPR -> /home/oracle/e2e/oradata2/DGSPR_S"
  echo "   3) [redo] /var/tmp/oracle/e2e/redo -> /var/tmp/oracle/e2e/redo"
  printf "Accept all mappings [Enter], or enter a number to edit: "; read -r n; echo "picked=[$n]"
  [[ -z "$n" ]] && break
  printf "New standby redo directory for '/var/tmp/oracle/e2e/redo' [/var/tmp/oracle/e2e/redo]: "; read -r d; echo "newdir=[$d]"
done
EOF
chmod +x "$TMP/fake3.sh"
printf '%s\n' \
 '^ *([0-9]+)\) \[(data|redo)\] /var/tmp/oracle/e2e/redo -> [^\n]*\n(?:.*\n)*?Accept all mappings \[Enter\], or enter a number to edit:	\1	once' \
 "New standby (data|redo) directory for '/var/tmp/oracle/e2e/redo' \[[^]]*\]:	/var/tmp/oracle/e2e_stby/redo_a" \
 'Accept all mappings \[Enter\], or enter a number to edit:	' > "$TMP/rules4.txt"
python3 "$E2E/lib/answer.py" --rules "$TMP/rules4.txt" --log "$TMP/run4.log" --grace 3 -- "$TMP/fake3.sh" > "$TMP/out4.txt" 2>&1; rc=$?
out=$(tr -d '\r' < "$TMP/out4.txt")
check "capture group picks row 3 by its text" 'grep -q "picked=\[3\]" <<< "$out"'
check "override directory answered, then the table accepted" 'grep -q "newdir=\[/var/tmp/oracle/e2e_stby/redo_a\]" <<< "$out" && grep -q "picked=\[\]" <<< "$out" && [[ $rc -eq 0 ]]'

# ---------------------------------------------------------------------------
echo "2. syntax"
# ---------------------------------------------------------------------------
ok=1
for f in "$E2E/e2e.sh" "$E2E"/lib/*.sh "$E2E"/checks/*.sh "$E2E"/proofs/*.sh; do
    bash -n "$f" 2>/dev/null || { fail "bash -n $f"; ok=0; }
done
[[ $ok -eq 1 ]] && pass "bash -n on e2e.sh, lib/, checks/, proofs/"
python3 -m py_compile "$E2E/lib/answer.py" 2>/dev/null && pass "answer.py compiles" || fail "answer.py compiles"
for f in "$E2E"/answers/*.rules; do
    if grep -v '^#' "$f" | grep -v '^$' | grep -qv $'\t'; then fail "$(basename "$f"): a rule line has no TAB"; ok=0; fi
done
pass "every rule line is TAB separated"

# ---------------------------------------------------------------------------
echo "3. scenario loading"
# ---------------------------------------------------------------------------
cat > "$TMP/config.env" <<'EOF'
PRIMARY_HOST="pri"; STANDBY_HOST="stb"; SSH_USER="oracle"
ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"; ORACLE_BASE="/u01/app/oracle"
NFS_SHARE="/nfs"; REPO_DIR="/home/oracle/repo"
LAB_FS_SLOTS="/u01/app/oracle /home/oracle /var/tmp/oracle"
LAB_FS_RENAME_TARGET="/tmp"; LAB_SCRATCH="/home/oracle/e2e"; LAB_SCRATCH_PORT="1531"
HOST3="obs"
EOF
(
    E2E_DIR="$E2E"; E2E_CONFIG="$TMP/config.env"
    source "$E2E/lib/common.sh"; source "$E2E/lib/scenario.sh"
    load_config || { echo "config load failed"; exit 1; }
    ids=$(scenario_ids); n=$(printf '%s\n' "$ids" | grep -c .)
    [[ $n -ge 14 ]] && echo "PASS catalog has $n scenarios" || echo "FAIL catalog has $n scenarios"
    for id in $ids; do
        if ! load_scenario "$id" >/dev/null 2>&1; then echo "FAIL load $id"; continue; fi
        if scenario_dump | grep -q '{FS[0-9]'; then echo "FAIL $id: unexpanded placeholder: $(scenario_dump | grep '{FS[0-9]' | head -1)"; continue; fi
        if scenario_dump | grep -q '{RENAME}\|{SCRATCH}'; then echo "FAIL $id: unexpanded {RENAME}/{SCRATCH}"; continue; fi
        [[ -n "$SCN_STANDBY_NAME" && -n "$P_SID" && -n "$S_NEEDS" ]] || { echo "FAIL $id: derived names missing"; continue; }
        echo "PASS $id loads (${SCN_KIND}, ${P_ID}, needs: ${S_NEEDS})"
    done
    SCN_LOG="/tmp/keep-me"; load_scenario s02 >/dev/null
    [[ "${SCN_LOG:-}" == "/tmp/keep-me" ]] && echo "PASS the runner's SCN_LOG survives load_scenario" || echo "FAIL SCN_LOG was reset by load_scenario"
    [[ "$WANT_FS_MAP" == "/home=/tmp /var=/tmp" ]] && echo "PASS s02 Q1b map expands to first components: $WANT_FS_MAP" || echo "FAIL s02 Q1b map: $WANT_FS_MAP"
    [[ "$P_DATA_DIRS" == "/u01/app/oracle/e2e/oradata/DGSPR /home/oracle/e2e/oradata2/DGSPR" ]] && echo "PASS p02 data dirs on slots" || echo "FAIL p02 data dirs: $P_DATA_DIRS"
    case " $S_NEEDS " in *" fs2 "*" fs3 "*|*" fs3 "*" fs2 "*|*" fs2 "*) ;; esac
    [[ "$S_NEEDS" == *fs2* && "$S_NEEDS" == *fs3* && "$S_NEEDS" == *rename-target* ]] && echo "PASS s02 needs fs2 fs3 rename-target" || echo "FAIL s02 needs: $S_NEEDS"
    [[ "$E2E_REMOTE_TNS_ADMIN" == "/home/oracle/e2e/net_s02" && "$SCN_PORT" == "1531" ]] && echo "PASS s02 scratch network on 1531" || echo "FAIL s02 net: $E2E_REMOTE_TNS_ADMIN $SCN_PORT"
    load_scenario s01 >/dev/null
    [[ -z "$E2E_REMOTE_TNS_ADMIN" && "$SCN_PORT" == "1521" ]] && echo "PASS s01 shared network on 1521" || echo "FAIL s01 net: '$E2E_REMOTE_TNS_ADMIN' $SCN_PORT"
    load_scenario s06 >/dev/null
    [[ "$S_NEEDS" == *host3* && "$S_NEEDS" == *mem2g* && "$P_FLASHBACK" == "yes" && "$P_FRA_DIR" == "/u01/app/oracle/e2e/fra_dgcdb" ]] && echo "PASS s06 needs host3+mem2g, overrides applied" || echo "FAIL s06: $S_NEEDS flashback=$P_FLASHBACK fra=$P_FRA_DIR"
    load_scenario s09 >/dev/null
    [[ "$S_NEEDS" == *obase-sibling* && "$WANT_STANDBY_ORACLE_BASE" == "/u01/app/oracle_stby" ]] && echo "PASS s09 needs obase-sibling" || echo "FAIL s09: $S_NEEDS $WANT_STANDBY_ORACLE_BASE"
    load_scenario s10 >/dev/null
    [[ "$P_SID" == "dgq1" && "$P_DB_UNIQUE_NAME" == "dgqrk_a" && "$SCN_PORT" == "1541" && "$SCN_STANDBY_SID" == "dgq2" ]] && echo "PASS s10 quirks names/port" || echo "FAIL s10: $P_SID $P_DB_UNIQUE_NAME $SCN_PORT $SCN_STANDBY_SID"
    load_scenario r03 >/dev/null
    [[ "$CASE_COUNT" == "5" && "$CASE_5_ANSWERS" == *'<TAB>n' ]] && echo "PASS r03 cases loaded" || echo "FAIL r03: $CASE_COUNT"
    source "$E2E/lib/refusal.sh"
    cr=$(case_rules 5)
    [[ "$cr" == "rule:Continue anyway\\?\\nDo you want to proceed\\? \\[y/N\\]:	n" ]] && echo "PASS r03 case 5 answers become one rule: line (TAB converted)" || echo "FAIL case_rules 5: $(printf '%s' "$cr" | cat -A)"
    [[ -z "$(case_rules 1)" ]] && echo "PASS a case without answers yields no rule" || echo "FAIL case_rules 1 not empty"
    load_scenario r02 >/dev/null
    [[ "$(case_rules 1)" == "rule:Storage mode \\[1\\]:	2" ]] && echo "PASS r02 case 1 picks OMF" || echo "FAIL case_rules r02: $(case_rules 1 | cat -A)"
    [[ "$(scenario_ids smoke | tr '\n' ' ')" == "r03 s01 " ]] && echo "PASS smoke tier = r03 s01" || echo "FAIL smoke tier: $(scenario_ids smoke | tr '\n' ' ')"
) > "$TMP/section.out" 2>&1; while IFS= read -r l; do case "$l" in PASS*) pass "${l#PASS }" ;; FAIL*) fail "${l#FAIL }" ;; *) echo "  $l" ;; esac; done < "$TMP/section.out"

# ---------------------------------------------------------------------------
echo "4. rule composition"
# ---------------------------------------------------------------------------
(
    E2E_DIR="$E2E"; E2E_CONFIG="$TMP/config.env"
    source "$E2E/lib/common.sh"; source "$E2E/lib/drive.sh"
    load_config
    STANDBY_NAME="dgtest_s"; SYS_PASSWORD='p@ss&word'
    _compose_rules "$TMP/composed" "rule:^custom:	x" step5
    grep -q "^Type 'dgtest_s' to continue:	dgtest_s" "$TMP/composed" && echo "PASS @STANDBY_NAME@ expanded in step5 rules" || echo "FAIL expansion"
    grep -qF "^custom:	x" "$TMP/composed" && echo "PASS inline rule: lines included first" || echo "FAIL inline rule"
    grep -q "p@ss&word" "$TMP/composed" && echo "PASS @SYS_PASSWORD@ with & and @ expanded verbatim" || echo "FAIL password expansion"
    tail -1 "$TMP/composed" | grep -q 'Select' && echo "PASS common.rules appended last" || echo "FAIL common last"
    _mask_rules "$TMP/composed" | grep -q 'p@ss&word' && echo "FAIL secret not masked" || echo "PASS secrets masked in the kept copy"
    grep -c "@[A-Z_]*@" "$TMP/composed" | grep -q '^0$' && echo "PASS no unexpanded token left" || echo "FAIL unexpanded: $(grep -o '@[A-Z_]*@' "$TMP/composed" | sort -u | tr '\n' ' ')"
) > "$TMP/section.out" 2>&1; while IFS= read -r l; do case "$l" in PASS*) pass "${l#PASS }" ;; FAIL*) fail "${l#FAIL }" ;; esac; done < "$TMP/section.out"

# ---------------------------------------------------------------------------
echo "5. step 2 scenario rules against a fake review table"
# ---------------------------------------------------------------------------
(
    E2E_DIR="$E2E"; E2E_CONFIG="$TMP/config.env"
    source "$E2E/lib/common.sh"; source "$E2E/lib/scenario.sh"; source "$E2E/lib/drive.sh"
    source "$E2E/lib/ssh.sh"; source "$E2E/lib/provision.sh"; source "$E2E/lib/build.sh"
    load_config; load_scenario s09 >/dev/null
    derive_answers
    _step2_scenario_rules > "$TMP/s09_rules"
    n=$(grep -c . "$TMP/s09_rules")
    [[ $n -eq 8 ]] && echo "PASS s09 produces 8 rule lines (4 overrides x 2)" || echo "FAIL s09 rule lines: $n"
    sed 's/^rule://' "$TMP/s09_rules" > "$TMP/s09_rules.txt"
    printf 'Accept all mappings \\[Enter\\], or enter a number to edit:\t\n' >> "$TMP/s09_rules.txt"
    cat > "$TMP/table.sh" <<'EOF'
#!/usr/bin/env bash
D1="/u01/app/oracle/e2e/oradata/DGSPR"; D2="/home/oracle/e2e/oradata2/DGSPR"; R1="/var/tmp/oracle/e2e/redo"; R2="/home/oracle/e2e/redo2"
S1="/u01/app/oracle/e2e/oradata/DGSPR_S"; S2="/home/oracle/e2e/oradata2/DGSPR_S"; T1="$R1"; T2="$R2"
while :; do
  echo "Derived primary -> standby directory mappings:"
  printf "  %2d) [data] %s -> %s\n" 1 "$D1" "$S1"; printf "  %2d) [data] %s -> %s\n" 2 "$D2" "$S2"
  printf "  %2d) [redo] %s -> %s\n" 3 "$R1" "$T1"; printf "  %2d) [redo] %s -> %s\n" 4 "$R2" "$T2"
  printf "Accept all mappings [Enter], or enter a number to edit: "; read -r n
  [[ -z "$n" ]] && break
  case "$n" in
    1) printf "New standby data directory for '%s' [%s]: " "$D1" "$S1"; read -r S1 ;;
    2) printf "New standby data directory for '%s' [%s]: " "$D2" "$S2"; read -r S2 ;;
    3) printf "New standby redo directory for '%s' [%s]: " "$R1" "$T1"; read -r T1 ;;
    4) printf "New standby redo directory for '%s' [%s]: " "$R2" "$T2"; read -r T2 ;;
  esac
done
echo "FINAL $S1 $S2 $T1 $T2"
EOF
    chmod +x "$TMP/table.sh"
    python3 "$E2E/lib/answer.py" --rules "$TMP/s09_rules.txt" --log "$TMP/table.log" --grace 3 -- "$TMP/table.sh" > "$TMP/table.out" 2>&1
    want="FINAL /u01/app/oracle/e2e_stby/data_a /home/oracle/e2e_stby/data_b /var/tmp/oracle/e2e_stby/redo_a /home/oracle/e2e_stby/redo_b"
    grep -q "^${want}" "$TMP/table.out" && echo "PASS all four review-table rows overridden by text, table then accepted" || echo "FAIL review table: $(grep FINAL "$TMP/table.out")"
    [[ "$(grep -ac '^\[prompt\]' "$TMP/table.log")" == "9" ]] && echo "PASS 9 prompts: 4 picks, 4 directories, 1 accept" || echo "FAIL prompt count $(grep -ac '^\[prompt\]' "$TMP/table.log")"
    load_scenario s02 >/dev/null; derive_answers
    [[ "$STANDBY_HOST" == "stb" && "$PRIMARY_HOST" == "pri" && "$ANS_STANDBY_HOST" == "stb" ]] && echo "PASS derive_answers leaves the ssh targets alone" || echo "FAIL derive_answers clobbered a config variable: STANDBY_HOST=$STANDBY_HOST"
    _step2_scenario_rules > "$TMP/s02_rules"
    grep -qF 'rule:Standby filesystem for /home \([^)]*\) \[[^]]*\]:	/tmp' "$TMP/s02_rules" && echo "PASS s02 Q1b per-filesystem rule for /home -> /tmp" || echo "FAIL s02 Q1b rule: $(cat "$TMP/s02_rules")"
    [[ "$Q1B_ANSWER" == "y" && "$ARCHIVE_CHOICE" == "2" && "$SRL_ANSWER" == "y" && "$STANDBY_SRL_DIR" == "/u01/app/oracle/e2e/srl/dgspr_s" ]] && echo "PASS s02 derived answers (Q1b=y, explicit archive, separate SRL dir)" || echo "FAIL s02 answers: $Q1B_ANSWER $ARCHIVE_CHOICE $SRL_ANSWER $STANDBY_SRL_DIR"
    load_scenario s03 >/dev/null; derive_answers
    [[ "$STORAGE_CHOICE" == "2" && -z "$ARCHIVE_CHOICE" && "$STANDBY_FRA_PATH" == "/home/oracle/e2e/fra_stby" && "$STANDBY_FRA_SIZE" == "10G" ]] && echo "PASS s03 derived answers (OMF, FRA path/size, archive question not asked)" || echo "FAIL s03 answers: $STORAGE_CHOICE '$ARCHIVE_CHOICE' $STANDBY_FRA_PATH $STANDBY_FRA_SIZE"
) > "$TMP/section.out" 2>&1; while IFS= read -r l; do case "$l" in PASS*) pass "${l#PASS }" ;; FAIL*) fail "${l#FAIL }" ;; esac; done < "$TMP/section.out"

# ---------------------------------------------------------------------------
echo "6. doctor resolution"
# ---------------------------------------------------------------------------
(
    E2E_DIR="$E2E"; E2E_CONFIG="$TMP/config.env"; LOG_ROOT="$TMP/logs"; mkdir -p "$LOG_ROOT"
    source "$E2E/lib/common.sh"; source "$E2E/lib/scenario.sh"; source "$E2E/lib/doctor.sh"
    load_config
    CAP_PY_PRIMARY=3.9.18; CAP_PY_STANDBY=3.9.18
    CAP_SLOT1_PRIMARY=ok; CAP_SLOT1_STANDBY=ok; CAP_SLOT2_PRIMARY=ok; CAP_SLOT2_STANDBY=ok
    CAP_SLOT3_PRIMARY="missing (mkdir -p /var/tmp/oracle failed)"; CAP_SLOT3_STANDBY=ok
    CAP_RENAME_STANDBY=ok; CAP_OBASE_SIBLING_STANDBY=no; CAP_SSH_HOST3=no; CAP_HOST3_DGMGRL=no
    CAP_MEM_PRIMARY=3000; CAP_MEM_STANDBY=1000; CAP_SLOT1_FREE_PRIMARY=20000; CAP_SLOT1_FREE_STANDBY=20000
    CAP_PORT_FREE_PRIMARY=yes; CAP_PORT_FREE_STANDBY=yes
    [[ -z "$(doctor_unmet "python3 fs2 rename-target mem1g")" ]] && echo "PASS all met: python3 fs2 rename-target mem1g" || echo "FAIL met: $(doctor_unmet "python3 fs2 rename-target mem1g")"
    doctor_unmet "fs3" | grep -q "slot 3 (/var/tmp/oracle) on the primary: missing" && echo "PASS fs3 unmet names the slot, host and reason" || echo "FAIL fs3: $(doctor_unmet fs3)"
    doctor_unmet "obase-sibling" | grep -q "chown oracle /u01/app" && echo "PASS obase-sibling prints the root fix" || echo "FAIL obase: $(doctor_unmet obase-sibling)"
    doctor_unmet "host3" | grep -q "HOST3" && echo "PASS host3 unmet" || echo "FAIL host3"
    doctor_unmet "mem2g" | grep -q "standby 1000 MB" && echo "PASS mem2g unmet with the numbers" || echo "FAIL mem2g: $(doctor_unmet mem2g)"
    [[ -z "$(doctor_unmet mem1g)" ]] && echo "PASS mem1g met at 1000 MB (lazy SGA: the gate is 600)" || echo "FAIL mem1g: $(doctor_unmet mem1g)"
    doctor_unmet "nonsense" | grep -q "unknown prerequisite" && echo "PASS unknown token reported" || echo "FAIL unknown token"
) > "$TMP/section.out" 2>&1; while IFS= read -r l; do case "$l" in PASS*) pass "${l#PASS }" ;; FAIL*) fail "${l#FAIL }" ;; esac; done < "$TMP/section.out"

# ---------------------------------------------------------------------------
echo "7. remote script generation under set -u (every scenario)"
# ---------------------------------------------------------------------------
(
    set -u
    E2E_DIR="$E2E"; E2E_CONFIG="$TMP/config.env"; LOG_ROOT="$TMP/logs"
    source "$E2E/lib/common.sh"; for f in ssh assert scenario doctor provision teardown drive build refusal checks report; do source "$E2E/lib/$f.sh"; done
    load_config
    for id in $(scenario_ids); do
        SCN_LOG="$TMP/logs/$id"; mkdir -p "$SCN_LOG/provision" "$SCN_LOG/build"
        load_scenario "$id" >/dev/null || { echo "FAIL $id: load under set -u"; continue; }
        derive_answers || { echo "FAIL $id: derive_answers under set -u"; continue; }
        _dbca_args > "$SCN_LOG/dbca.args" || { echo "FAIL $id: _dbca_args"; continue; }
        _remote_reshape > "$SCN_LOG/reshape.sh" || { echo "FAIL $id: _remote_reshape"; continue; }
        bash -n "$SCN_LOG/reshape.sh" || { echo "FAIL $id: reshape.sh does not parse"; continue; }
        # dynamic SQL built from shell strings: a line with an odd number of quotes is an ORA-01756 waiting to happen
        if grep -E "EXECUTE IMMEDIATE|^ALTER |^CREATE |^INSERT " "$SCN_LOG/reshape.sh" | awk -F"'" 'NF % 2 == 0 { print; bad=1 } END { exit bad }' > "$TMP/oddq.txt"; then :; else echo "FAIL $id: odd number of quotes in: $(head -1 "$TMP/oddq.txt")"; continue; fi
        _remote_db_cleanup standby "$SCN_STANDBY_SID" "$SCN_STANDBY_NAME" "$(_rm_list $(_standby_dirs))" > "$SCN_LOG/td_standby.sh" || { echo "FAIL $id: standby teardown script"; continue; }
        _remote_db_cleanup primary "$P_SID" "$P_DB_UNIQUE_NAME" "$(_rm_list $(_primary_dirs))" > "$SCN_LOG/td_primary.sh" || { echo "FAIL $id: primary teardown script"; continue; }
        bash -n "$SCN_LOG/td_standby.sh" && bash -n "$SCN_LOG/td_primary.sh" || { echo "FAIL $id: teardown scripts do not parse"; continue; }
        _step2_scenario_rules > "$SCN_LOG/step2.rules" || { echo "FAIL $id: step2 rules"; continue; }
        _shape_query > /dev/null
        grep -q "rm -rf " "$SCN_LOG/td_primary.sh" || { echo "FAIL $id: teardown removes nothing"; continue; }
        grep -qE "rm -rf .*'/'( |$)|rm -rf '/u01'( |$)|rm -rf '/home/oracle'( |$)" "$SCN_LOG/td_primary.sh" "$SCN_LOG/td_standby.sh" && { echo "FAIL $id: teardown would remove a bare root/slot directory"; continue; }
        echo "PASS $id: dbca args, reshape, teardown scripts and step 2 rules generate under set -u"
    done
    load_scenario s01 >/dev/null; SCN_LOG="$TMP/logs/s01"
    grep -q -- "-createAsContainerDatabase false" "$SCN_LOG/dbca.args" && echo "PASS s01 DBCA non-CDB" || echo "FAIL s01 dbca: $(cat "$SCN_LOG/dbca.args")"
    awk '/WHENEVER SQLERROR CONTINUE/{tol=1} /WHENEVER SQLERROR EXIT/{tol=0} /ALTER SYSTEM RESET/ && !tol {bad=1} END{exit bad}' "$SCN_LOG/reshape.sh" && echo "PASS every ALTER SYSTEM RESET runs in a tolerant block (ORA-32010 is fine)" || echo "FAIL a RESET runs under WHENEVER SQLERROR EXIT"
    grep -q "oradata/DGTEST" "$SCN_LOG/td_primary.sh" && echo "PASS s01 teardown names the DGTEST directory" || echo "FAIL s01 teardown dirs"
    grep -q "DGTEST_S" "$SCN_LOG/td_standby.sh" && echo "PASS s01 standby teardown names DGTEST_S" || echo "FAIL s01 standby teardown"
    load_scenario s04 >/dev/null; SCN_LOG="$TMP/logs/s04"
    grep -q -- "-createAsContainerDatabase true" "$SCN_LOG/dbca.args" && grep -q "db_domain=world" "$SCN_LOG/dbca.args" && echo "PASS s04 DBCA CDB with db_domain" || echo "FAIL s04 dbca: $(cat "$SCN_LOG/dbca.args")"
    grep -q "CREATE USER c##e2e" "$SCN_LOG/reshape.sh" && grep -q "CONTAINER=ALL" "$SCN_LOG/reshape.sh" && echo "PASS s04 marker schema is a common user" || echo "FAIL s04 marker schema"
    grep -q "CREATE PLUGGABLE DATABASE pdb1" "$SCN_LOG/reshape.sh" && grep -q "ALTER SESSION SET CONTAINER = pdb1" "$SCN_LOG/reshape.sh" && echo "PASS s04 PDBs and PDB services in the reshape" || echo "FAIL s04 pdbs"
    load_scenario s02 >/dev/null; SCN_LOG="$TMP/logs/s02"
    grep -q "control_files = '/u01/app/oracle/e2e/oradata/DGSPR/control01.ctl', '/var/tmp/oracle/e2e/redo/control02.ctl'" "$SCN_LOG/reshape.sh" && echo "PASS p02 explicit control files in the reshape" || echo "FAIL p02 control files"
    grep -q "/tmp/oracle/e2e/oradata2/DGSPR_S" "$SCN_LOG/td_standby.sh" && echo "PASS s02 teardown follows the Q1b rename to /tmp" || echo "FAIL s02 teardown rename: $(grep 'rm -rf' "$SCN_LOG/td_standby.sh" | head -2)"
    load_scenario s10 >/dev/null; SCN_LOG="$TMP/logs/s10"
    grep -q "dg_broker_config_file1 = '/u01/app/oracle/e2e/broker/dgqrk/dr1dgqrk_a.dat'" "$SCN_LOG/reshape.sh" && grep -qF "ADD STANDBY LOGFILE (''/u01/app/oracle/oradata/DGQRK_A/srl' || LPAD(g, 2, '0') || '.log'') SIZE 100M REUSE" "$SCN_LOG/reshape.sh" && ! grep -q "ADD STANDBY LOGFILE THREAD" "$SCN_LOG/reshape.sh" && echo "PASS p06 broker files and undersized THREAD-less SRLs" || echo "FAIL p06 reshape"
) > "$TMP/section.out" 2>&1; while IFS= read -r l; do case "$l" in PASS*) pass "${l#PASS }" ;; FAIL*) fail "${l#FAIL }" ;; *) echo "  $l" ;; esac; done < "$TMP/section.out"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]

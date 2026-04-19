# Bug Fixes and Improvements

**Date:** 2026-04-19
**Scope:** Code review of the Oracle 19c Data Guard setup scripts. Fixes span critical control-flow bugs, AIX compatibility, and a regression introduced by the in-flight "extended path parameters" feature.

Each entry below documents **the problem**, **the fix**, **the files and lines** touched, and **why** the change matters. All scripts still pass `bash -n` after the changes.

---

## Critical bugs (would cause silent or catastrophic failure)

### 1. `((ERRORS++))` aborted the verification script on the first error

- **Files:** `standby/07_verify_dataguard.sh` (9 occurrences), `tests/test_add_sid_to_listener.sh` (2 occurrences)
- **Symptom:** Under `set -e` (which `enable_verbose_mode` turns on via `set -E -o pipefail` plus an ERR trap), `((VAR++))` returns a **non-zero exit status** when `VAR` was `0`, because post-increment yields the *old* value and bash treats `((0))` as "false." The very first error or warning in step 7 triggered the ERR trap and aborted the script before the summary ever ran.
- **Fix:** Replaced every `((ERRORS++))` / `((WARNINGS++))` with the pre-increment form `((++ERRORS))` / `((++WARNINGS))`. Pre-increment returns the *new* value, which is always ≥ 1 after the first bump, so the compound command exits 0.
- **Why it matters:** Without this fix, `07_verify_dataguard.sh` never reports a health summary when anything is actually wrong — it exits silently via the ERR trap. This is the script users trust to tell them the Data Guard setup is healthy.

### 2. RMAN duplicate silently discarded the new extended-path customizations

- **File:** `standby/05_clone_standby.sh`
- **Symptom:** Pending changes in `02_generate_standby_config.sh` let the user customize `STANDBY_AUDIT_FILE_DEST` and `STANDBY_DIAGNOSTIC_DEST`, and wrote them into the standby pfile. Step 5's RMAN `DUPLICATE ... SPFILE SET` block:
  1. Hardcoded `SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'` — overriding the user's choice.
  2. Never `SET DIAGNOSTIC_DEST` at all — so the standby SPFILE inherited the **primary's** `diagnostic_dest` path (which may not exist on the standby host).
- **Fix:** Both the OMF branch and the Traditional branch now emit:
  ```
  SET AUDIT_FILE_DEST='${STANDBY_AUDIT_FILE_DEST:-${STANDBY_ADMIN_DIR}/adump}'
  SET DIAGNOSTIC_DEST='${STANDBY_DIAGNOSTIC_DEST:-$STANDBY_ORACLE_BASE}'
  ```
  The `:-` fallbacks preserve the old behavior when the config doesn't define the new variables (older configs or regenerations).
- **Why it matters:** Without this fix, the "customizable extended paths" feature looks like it works (pfile is correct, step 3 installs it) but the RMAN SPFILE that actually runs the standby ignores it.

### 3. `df -k` is not AIX-compatible

- **File:** `standby/03_setup_standby_env.sh` (2 occurrences: disk-space preflight and separate-SRL preflight)
- **Symptom:** On AIX, plain `df -k` puts `%Used` in column 4 instead of "Available". The disk-space check read a percentage string (e.g. `77%`), divided it by 1024, and concluded that ~0 MB were available, aborting with "INSUFFICIENT DISK SPACE" regardless of actual free space.
- **Fix:** Changed both calls to `df -Pk` (POSIX format, kilobyte blocks). In POSIX output, column 4 is always "Available" on both Linux and AIX.
- **Why it matters:** `CLAUDE.md` explicitly calls out AIX 7.2 as a supported target. The rest of the codebase already uses `df -P`; these two call sites were regressions.

---

## High-impact issues (wrong behavior, but not always fatal)

### 4. Dead `if [[ $? -ne 0 ]]` checks after `set -e` commands

- **Files:** `fsfo/observer.sh` (3 occurrences after `mkstore` heredoc calls), `primary/06_configure_broker.sh` (2 occurrences after `run_dgmgrl`)
- **Symptom:** With `set -e` active, a command that fails triggers the ERR trap and exits the script **before** the next line runs. The explicit `if [[ $? -ne 0 ]]` checks that followed these calls were unreachable — on failure, the user saw a generic ERR-trap message instead of the targeted "Failed to create wallet / add credential / add database" error.
- **Fix:** Wrapped each call in the `if ! cmd; then ... fi` form. A failing command in the condition slot does **not** trigger set -e, so the targeted log_error + exit runs as intended.
- **Why it matters:** Operational debuggability. When broker creation fails, the operator needs to know which specific step failed, not just "command failed at line N".

### 5. Unanchored path substitutions could rewrite unrelated segments or silently share paths

- **File:** `primary/02_generate_standby_config.sh` (5 substitution sites + extended-path helper)
- **Symptom:** Substitutions used `sed "s/${PRIMARY_DIR_NAME}/${STANDBY_DIR_NAME}/g"` with `/` as the delimiter and no anchoring. Two concrete failure modes:
  1. **Overreach:** If the primary DB_UNIQUE_NAME is a substring of a parent directory (e.g., `prod` in `/u01/prodapp/prod/`), both occurrences get rewritten.
  2. **Silent sharing:** If `DB_RECOVERY_FILE_DEST` doesn't contain `PRIMARY_DIR_NAME` at all (e.g., `/u01/fra`), the substitution is a no-op and `STANDBY_FRA` equals the primary FRA path — primary and standby write into the same FRA with no warning.
- **Fix:** Introduced a `_substitute_dir_name` helper that:
  - Uses `|` as the sed delimiter (paths can't collide with it).
  - Anchors the match with a leading `/` and either a trailing `/` or end-of-string, so only *path segments* are rewritten.
  - Emits a `log_warn` when the substitution left a non-empty input unchanged, telling the operator that primary and standby will share the location and to edit the generated config before proceeding.
  
  Applied this helper to `STANDBY_DATA_PATH`, `STANDBY_REDO_PATH`, `STANDBY_SRL_PATH`, `STANDBY_FRA`, and `STANDBY_ARCHIVE_DEST`. The `_derive_ext_path` helper (for `diagnostic_dest` / `audit_file_dest`) was updated with the same anchoring.
- **Why it matters:** Silent sharing of FRA between primary and standby is the kind of bug that surfaces only in production when archived redo collides. The warning short-circuits that.

### 6. `ORACLE_BASE` fallback assumed a 2-level OFA layout

- **File:** `primary/01_gather_primary_info.sh`
- **Symptom:** `PRIMARY_ORACLE_BASE="${ORACLE_BASE:-$(dirname $(dirname $ORACLE_HOME))}"` assumed `ORACLE_HOME` is two levels below `ORACLE_BASE`. Standard OFA puts it **four** levels deep (`$ORACLE_BASE/product/19c/dbhome_1`). Also unquoted — a space in the path would split the args.
- **Fix:** Prefer `$ORACLE_BASE`, then call `$ORACLE_HOME/bin/orabase` (Oracle's own authoritative lookup), and abort with a clear error if neither is available. All variable uses are properly quoted.
- **Why it matters:** When the heuristic wrong-computed `ORACLE_BASE`, downstream paths (`admin/`, `adump/`, pfile comments) were pointed at a bogus directory on the standby.

### 7. FSFO step looked for the wrong password-file name

- **File:** `primary/09_configure_fsfo.sh`
- **Symptom:** Step 1 writes `${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}`. Step 9 searched for `${NFS_SHARE}/orapw${PRIMARY_DB_NAME}`. When SID ≠ DB_NAME, step 9 concluded "not present" and copied a **second** file under a new name, leaving two copies on NFS.
- **Fix:** Standardized on `${PRIMARY_ORACLE_SID}` to match step 1. Inline comment documents the contract.

### 8. Progress counter mismatches

- **Files:** 4 scripts called `init_progress N` with `N` not matching the actual count of `progress_step` invocations:
  | Script | Before | After |
  |---|---|---|
  | `primary/01_gather_primary_info.sh` | `init_progress 10` | `init_progress 11` |
  | `primary/04_prepare_primary_dg.sh` | `init_progress 7` | `init_progress 8` |
  | `primary/06_configure_broker.sh` | `init_progress 7` | `init_progress 8` |
  | `primary/09_configure_fsfo.sh` | `init_progress 14` | `init_progress 13` |
- **Symptom:** The log displayed confusing labels like `[8/7] Reviewing Current Data Guard Configuration`.
- **Fix:** Corrected each `init_progress` call to match the actual number of `progress_step` invocations.

### 9. Non-restartable state leak when operator declined the RMAN confirmation

- **File:** `standby/05_clone_standby.sh`
- **Symptom:** The typed-value confirmation (`STANDBY_DB_UNIQUE_NAME`) came **after** `STARTUP NOMOUNT`. If the operator changed their mind and declined, the script exited leaving the standby instance running in NOMOUNT with no cleanup. RMAN duplicate is not directly restartable (see `CLAUDE.md`), so this left a weird dangling state.
- **Fix:** Moved `confirm_typed_value` to immediately after `verify_sys_password`, before `STARTUP NOMOUNT`. Declining now exits cleanly with no side effects, and SYS_PASSWORD is cleared from memory.

### 10. Summary showed stale FORCE_LOGGING / DG_BROKER_START values

- **File:** `primary/04_prepare_primary_dg.sh`
- **Symptom:** `FORCE_LOGGING` was read once into a shell variable, possibly toggled via `ALTER DATABASE FORCE LOGGING`, but never re-read before the summary block. `DG_BROKER_START` had the same pattern. The summary block then reported the pre-change value, contradicting the log messages a few lines earlier.
- **Fix:** After the enabling `ALTER` runs successfully, the shell variable is assigned to the new value (`FORCE_LOGGING="YES"` / `DG_BROKER_START="TRUE"`). Chose variable assignment over a second SQL round-trip since the SQL command either succeeded or raised and exited.

### 11. FQDN detection used a fragile `host` heuristic

- **File:** `primary/01_gather_primary_info.sh`
- **Symptom:** `host "$HOSTNAME" | awk '/has address/{print $1}'` extracts the queried name (typically the short name we just fed it), not the FQDN. Also, `host` is not shipped by default on AIX.
- **Fix:** Prefer `hostname -f` (works on both Linux and AIX with a resolver that knows the FQDN), then fall back to `hostname` if `-f` returns empty. Removed the `host` dependency entirely.

### 12. RMAN script and log filenames could drift by one second

- **File:** `standby/05_clone_standby.sh`
- **Symptom:** `RMAN_SCRIPT` and `RMAN_LOG` each called `$(date ...)` independently. On a slow host that crossed a second boundary between those two assignments, the recorded artifacts pointed at two different timestamps, making post-run log correlation harder.
- **Fix:** Compute `RMAN_TS=$(date '+%Y%m%d_%H%M%S')` once, and interpolate it into both filenames.

### 13. RMAN exit-code capture was defeated by `set -e` + `pipefail`

- **File:** `standby/05_clone_standby.sh`
- **Symptom:** The RMAN call was wrapped in a subshell that wrote the exit code to a file so the outer script could inspect it. But under `set -e` + `pipefail`:
  1. The subshell inherited `set -e`. If RMAN failed, `echo $?` **never ran**, so the exit-code file was not written.
  2. The outer pipe `(subshell) | tee` had pipefail, so a non-zero subshell aborted the whole statement before the explicit exit-code check at line 385 could run.
- **Fix:** Added `set +e` **inside** the subshell so the `echo $?` always fires, and appended `|| true` to the outer pipeline so the pipefail failure doesn't abort before inspection. The explicit check that logs "RMAN duplicate failed with exit code: N — check the RMAN log" is now actually reachable.

---

## Lower-severity cleanups

### 14. `grep -q "$STANDBY_TNS_ALIAS"` could false-match on regex metacharacters

- **File:** `primary/04_prepare_primary_dg.sh`
- **Fix:** Switched to `grep -qF` (fixed-string). Dots in domain-qualified TNS aliases (e.g., `prod.example.com`) are no longer interpreted as regex wildcards.

### 15. `local_listener` port regex could grab digits from a host name

- **File:** `primary/01_gather_primary_info.sh`
- **Symptom:** `sed -n 's/.*[^0-9]\([0-9]\{4,5\}\)[^0-9].*/\1/p'` matched any 4–5 digit run. A hostname like `srv01234` matched before the real `PORT=1521` token.
- **Fix:** Narrowed the regex to `PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)` so only digits that appear as the `PORT=` value are accepted.

### 16. `dg_check_sid.sh` wrapper swallowed the real exit code

- **File:** `dg_check_sid.sh`
- **Symptom:** The deprecated wrapper ran `dg_triage_sid.sh "$@" || true ; exit 0`. CI pipelines still invoking the old name would always see success even when triage found real problems.
- **Fix:** Replaced with `exec bash "${SCRIPT_DIR}/dg_triage_sid.sh" "$@"`. `exec` replaces the current shell, so the real exit code propagates naturally.

---

## Issues reported but **not** fixed (design decisions left in place)

These were flagged in the review but intentionally left unchanged — either because the current behavior is defensible, or because changing it requires a larger design discussion. Listed here for traceability.

- **Control-file multiplexing** (`02_generate_standby_config.sh`, `05_clone_standby.sh`): both control files still live in `${STANDBY_DATA_PATH}` as `control01.ctl`/`control02.ctl`. Multiplexing across DATA + FRA is a larger OFA decision and should be an operator-visible prompt if we change it.
- **Listener snippet's full `LISTENER =` block** (`02_generate_standby_config.sh`): left as a reference snippet — step 3 merges into existing listener.ora correctly, and the snippet is labelled "Ensure LISTENER section exists" for humans reading it.
- **`_size_to_gb` treating bare integers as bytes** (`02_generate_standby_config.sh`): works for the actual Oracle outputs we see; changing it risks breaking genuine byte-count paths. Documented behavior is acceptable.
- **SQL*Plus credentials via command-line args in `08_security_hardening.sh`**: visible in `ps` output briefly. Documented trade-off; a secure-by-stdin rewrite is a follow-up.

---

## Files changed

| File | Lines touched | Summary |
|---|---|---|
| `standby/07_verify_dataguard.sh` | 9 | `((VAR++))` → `((++VAR))` |
| `tests/test_add_sid_to_listener.sh` | 2 | same as above |
| `standby/03_setup_standby_env.sh` | 2 | `df -k` → `df -Pk` |
| `standby/05_clone_standby.sh` | 4 sections | RMAN extended paths, timestamp, exit capture, confirmation order |
| `primary/01_gather_primary_info.sh` | 3 sections | ORACLE_BASE, FQDN, listener port regex, `init_progress` |
| `primary/02_generate_standby_config.sh` | 3 sections | anchored path substitutions + no-op warning |
| `primary/04_prepare_primary_dg.sh` | 4 edits | `init_progress`, `grep -qF`, stale FORCE_LOGGING / DG_BROKER_START |
| `primary/06_configure_broker.sh` | 2 edits | `init_progress`, dead `$?` checks |
| `primary/09_configure_fsfo.sh` | 2 edits | `init_progress`, password-file name |
| `fsfo/observer.sh` | 3 edits | dead `$?` checks |
| `dg_check_sid.sh` | 1 | propagate triage exit code via `exec` |

## Verification

All modified scripts pass `bash -n` (syntax check). Behavioral testing should run through the E2E harness (`tests/e2e/run_e2e_test.sh`) — especially:

- Step 3's disk-space preflight on an AIX target.
- Step 7 with a deliberately broken config (MRP stopped, archive gap) to confirm errors are counted and the summary reports them instead of aborting.
- Step 5 on a host where the primary and standby use different SIDs, to confirm the step-9 password-file path is found.
- Any path layout where the primary DB_UNIQUE_NAME does not appear in `DB_RECOVERY_FILE_DEST`, to confirm the new no-op warning fires.

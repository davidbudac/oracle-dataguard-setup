# Data Guard Setup Scripts — Improvement Implementation Plan

Findings from a full repo review (2026-07). Organized into workstreams ordered by severity. Each item lists the affected files, the concrete change, and how to verify. Constraints honored throughout: NFS share for config/state, AIX 7.2 compatibility (printf not `echo -e`, no `grep -P`, no GNU-isms), filesystem storage, single instance, DGMGRL-first.

Suggested implementation order: WS1 → WS2 → WS3 → WS4 → WS5 → WS6. WS1 and WS2 are independent of each other internally and can be done in any order within the workstream.

## Implementation status (2026-07-07)

Headings are marked ✅ (implemented) or ⏭️ (deliberately skipped). Summary:

- **Implemented:** all of WS1 (1.1–1.8), WS2 (2.1–2.6), WS3 (3.1–3.4), WS4.1–4.6, WS4.8, WS5, and WS6.1 (four new unit-test suites in `tests/`).
- **⏭️ 4.7 JSON output mode:** deferred — the plan itself says "discuss before building".
- **⏭️ 6.2–6.4 E2E additions (switchover assertion, observer lifecycle, CDB trigger coverage):** skipped at the user's request ("skip the e2e tests for now"). WS1.8's observer-grep fix (a prerequisite for 6.3) *is* in.
- **Verification performed:** all `tests/test_*.sh` pass; `bash -n` clean on every `*.sh` in the repo; static scan confirms no password-bearing process argv, no `grep -P`, no `\s`/`\|` grep patterns, no `((VAR++))` (the latter three enforced by the new `tests/test_grep_portability.sh` / `tests/test_counter_increment.sh` sweeps).
- **Verification still outstanding:** full E2E runs (non-CDB + CDB), the AIX spot checks (need the real box), live NFS permission checks, and a live `ps -ef` scan during clone/diag — see "Verification (overall)" below.
- Extras done during the sweep (beyond the itemized plan): same-class grep/portability fixes in `migrate_noncdb_to_pdb/`, `tests/e2e/run_e2e_test_cdb.sh`, and `dg_check_srl.sh` (including its password-on-argv); `nfs/02_mount_nfs_client.sh` no longer re-widens the share to 775.

---

## Workstream 1 — Critical bug fixes

### ✅ 1.1 Add `WHENEVER SQLERROR EXIT` to all SQL command scripts

**Problem:** No script in `sql/commands/` sets `WHENEVER SQLERROR EXIT SQL.SQLCODE`, so sqlplus exits 0 even when a statement raises ORA-. `run_sql_command`/`run_sql_script` in `common/dg_functions.sh` report success on failed `MOUNT STANDBY DATABASE`, `ADD STANDBY LOGFILE`, `ALTER SYSTEM SET`, `ALTER DATABASE FORCE LOGGING`, etc. `set -e` and the ERR trap never fire on SQL failure — steps silently continue half-done.

**Change:**
- Add to the top of every `sql/commands/*.sql`:
  ```
  WHENEVER SQLERROR EXIT SQL.SQLCODE
  WHENEVER OSERROR EXIT FAILURE
  ```
- Audit call sites: some callers deliberately tolerate errors (e.g. idempotent "already exists" paths). Where a statement may legitimately fail (e.g. `ADD STANDBY LOGFILE` when logs exist), either guard in SQL (`DECLARE ... EXCEPTION WHEN ...`) or wrap the call site with an explicit `|| handle`.
- Special case `secure_sys_account.sql`: with `WHENEVER SQLERROR EXIT`, a failed `ALTER USER SYS IDENTIFIED BY` (password verify function) now aborts *before* `ACCOUNT LOCK`, and the trailing `SELECT 'SUCCESS'` no longer masks failure. Reorder so the lock only happens after a successful password change.

**Verify:** unit-style test: run a command script against a deliberately failing statement (e.g. bad parameter name) and assert non-zero sqlplus exit. Then full E2E (`bash tests/e2e/run_e2e_test.sh`).

### ✅ 1.2 Fix `((VAR++))` aborts under `set -e` in the verifier

**Problem:** `standby/07_verify_dataguard.sh` lines 134, 142, 159, 177, 201, 232, 240, 297, 323 use `((ERRORS++))`/`((WARNINGS++))`. `((x++))` returns status 1 when x is 0, so under `set -e` + ERR trap the *first* recorded problem kills the whole health check instead of tallying.

**Change:** replace every occurrence with `ERRORS=$((ERRORS+1))` / `WARNINGS=$((WARNINGS+1))`. Grep the whole repo for `((.*++))` to catch any other instances.

**Verify:** run step 7 against a config with a known warning (e.g. flashback off) and confirm the full report prints with the summary tally.

### ✅ 1.3 Fix AIX `df` column parsing in step 3

**Problem:** `standby/03_setup_standby_env.sh:93,160` parse free space with `df -k ... | awk '{print $4}'`. On AIX 7.2, `df -k` field 4 is `%Used` (free KB is field 3), so `AVAILABLE_SPACE_KB` becomes e.g. `50%` and the arithmetic aborts the script. (The filesystem detection two lines up already uses `df -P` correctly.)

**Change:** use `df -Pk "$path" | tail -1 | awk '{print $4}'` — with `-P` the output is POSIX-normalized on both Linux and AIX and field 4 is Available.

**Verify:** on Linux, confirm identical values before/after; sanity-check `df -Pk` output columns on the real AIX box.

### ✅ 1.4 Step 8 hardening: propagate the new password file to the standby

**Problem:** `primary/08_security_hardening.sh:149-170` randomizes the SYS password but never copies the regenerated `orapw<SID>` to the standby. In 19c redo transport authenticates via the password file → ORA-16191 / transport failure on next reconnect or restart. It also silently makes a future re-clone (step 5) impossible.

**Change:**
- After the password change, copy the primary's refreshed password file to the NFS share and print explicit instructions (or add a small helper) to install it on the standby (`$ORACLE_HOME/dbs/orapw<STANDBY_SID>`), then verify transport with `SHOW CONFIGURATION` before declaring success.
- Add a post-change check: query `V$ARCHIVE_DEST_STATUS` / broker for transport errors and fail loudly if ORA-16191 appears.
- Add a warning in `standby/05_clone_standby.sh` pre-flight: if the SYS account is locked (detectable via failed `verify_sys_password` + `ORA-28000`), print the documented unlock/re-harden procedure.

**Verify:** E2E: run step 8, restart transport (defer/enable via DGMGRL), confirm no ORA-16191 and logs still ship.

### ✅ 1.5 Replace AIX-missing `base64`/`head -c` in password generation

**Problem:** `primary/08_security_hardening.sh:149`: `dd ... | base64 | ... | head -c 32`. AIX 7.2 base install has no `base64`, and AIX `head` has no `-c`.

**Change:** use `openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32` (openssl ships with Oracle installs; `cut -c` is POSIX). Guard with `command -v openssl` and fall back to `od -An -tx1 /dev/urandom | tr -d ' \n' | cut -c1-32`.

**Verify:** run the generator snippet standalone on Linux; check `command -v base64 head cut od` expectations on the AIX box.

### ✅ 1.6 Fix AIX-incompatible grep patterns in the status/diag stack

**Problem:**
- `\|` alternation in BRE (GNU extension, literal on AIX): `dg_status.sh:727`, `common/dg_local_status_common.sh:931`, `common/setup_dg_wallet.sh:142`. Broker-not-configured detection never fires on AIX.
- `\s`/`\S` in ERE (PCRE-ism): `dg_status.sh:741`, `common/dg_local_status_common.sh:947,1428`. Per-member broker Error/Warning detection misfires. (`dg_handoff.sh:186` already documents avoiding `\s` — apply the rule consistently.)

**Change:** convert to `grep -E 'a|b|c'` and `[[:space:]]`/`[^[:space:]]`. Then sweep the whole repo: `grep -rnE '\\\\[|sS]' --include='*.sh'` and review each hit.

**Verify:** unit test the specific patterns against captured DGMGRL output samples (both "configured" and "ORA-16532" cases); confirm identical behavior on Linux.

### ✅ 1.7 Harden SID auto-detection and add SSH failure detection in `dg_status.sh`

**Problem:** `dg_status.sh:242-252`:
- `grep ora_pmon_` matches `ora_pmon_+ASM`; `head -1` may pick it.
- `_ssh_raw` merges stderr (`2>&1`); on SSH failure `$PMON` is the error text, `sed 's/.*ora_pmon_//'` passes it through unchanged, the non-empty guard passes, and the script proceeds with a garbage SID.
- More broadly (`:94-109`, consumed at `:266-399`): no remote call ever checks SSH success; a dead standby renders as blank fields and the dashboard can still print HEALTHY.

**Change:**
- Filter: `grep '[o]ra_pmon_' | grep -v '+ASM'`; validate the extracted SID against `^[A-Za-z][A-Za-z0-9_$]*$`; abort with a clear message otherwise.
- Add an explicit connectivity pre-check per host (`_ssh_raw host 'echo DG_SSH_OK'` and require the token). On failure: print `ERROR: cannot SSH to <host>`, count it in `ERRORS`, and clearly mark that side's panel as UNREACHABLE instead of blank.
- Add a config pre-flight: verify required keys (`JUMP_HOST`, `PRIMARY_ORACLE_HOSTNAME`, `STANDBY_ORACLE_HOSTNAME`, `SSH_OPTS`, `ORACLE_BASE`, …) are set after sourcing, with a friendly message listing missing ones (replaces cryptic `set -u` aborts).

**Verify:** run against config with a bogus standby host → expect explicit UNREACHABLE + non-zero errors; run normal case unchanged.

### ✅ 1.8 Fix case-sensitive observer greps in E2E

**Problem:** `tests/e2e/run_e2e_test.sh:422` (`pkill -f 'dgmgrl.*observer'`) and `:1255` (`grep -q 'dgmgrl.*observer'`) never match the real process (`dgmgrl /@... "START OBSERVER"`). Cleanup leaves zombie observers; the running-assertion can only fail. Masked because `SKIP_OBSERVER` defaults `true`.

**Change:** use case-insensitive matching (`grep -qi`, `pkill -fi` where supported; otherwise match `'dgmgrl.*[Oo][Bb][Ss][Ee][Rr][Vv][Ee][Rr]'` or the literal `OBSERVER`).

**Verify:** covered by WS6.3 (enable observer in E2E).

---

## Workstream 2 — Robustness

### ✅ 2.1 Remove dead `$?` error handlers under `set -e`

**Problem:** With `set -e`, a failing bare command aborts before the following `if [[ $? -ne 0 ]]` runs — the hand-written error messages are dead code:
- `primary/09_configure_fsfo.sh:364-365` (`DGMGRL_OUTPUT=$(run_dgmgrl ...)` then `$?` check)
- `primary/06_configure_broker.sh:204,215`
- `fsfo/observer.sh:178-191,237,248` (mkstore calls; `-createSSO` at 189 has no check at all)

**Change:** capture status explicitly: `if ! OUTPUT=$(cmd 2>&1); then log_error ...; fi`, or append `|| RC=$?` with `RC=0` pre-set. Pick one idiom and apply consistently.

**Verify:** force a dgmgrl failure (bad credentials) and confirm the tailored message now appears instead of the raw ERR-trap line.

### ✅ 2.2 Observer pidfile validation

**Problem:** `fsfo/observer.sh:73-81` trusts the PID from the NFS pidfile with only `kill -0`. After a reboot, a recycled PID belonging to an unrelated process makes `status` report running, `start` refuse, and `stop` kill the wrong process.

**Change:** in `is_observer_running`, after `kill -0`, verify the command line: `ps -p "$pid" -o args= 2>/dev/null | grep -qi 'dgmgrl'` (POSIX `ps -o args=` works on AIX). If the pidfile is stale, remove it and report not-running.

**Verify:** write a pidfile with the PID of a live non-dgmgrl process; `observer.sh status` must report NOT RUNNING and clean the stale file; `start` must proceed.

### ✅ 2.3 Safe wallet recreation (copy-then-replace)

**Problem:**
- `fsfo/observer.sh:139-142`: `backup_directory` *moves* the live wallet away before `mkstore -create`; if creation fails, no working wallet remains.
- `common/setup_dg_wallet.sh:228-233` (`-A` mode): silently recreates a wallet that may hold unrelated credentials.

**Change:** build the new wallet in a temp dir first; only swap into place after successful creation + credential add (mv old → `.bak`, mv new → live). In `setup_dg_wallet.sh -A`, first list existing credentials (`mkstore -listCredential`) and warn/confirm before recreating; without confirmation, add/update credentials in the existing wallet instead.

**Verify:** simulate mkstore failure (bad wallet password on an existing wallet) and confirm the original wallet is untouched.

### ✅ 2.4 Degrade gracefully in `dg_handoff.sh`

**Problem:** `set -e` (line 25) + `WHENEVER SQLERROR EXIT 1` (lines 87-92) on ~15 `VAR=$(run_sql …)` assignments — one transient ORA- error kills the whole report.

**Change:** wrap discovery assignments as `VAR=$(run_sql ... ) || VAR=""` and render missing fields as `n/a` with a warning list at the end of the report. Keep the initial connectivity check fatal.

**Verify:** run with broker down (`SHOW DATABASE VERBOSE` failing) — report should still emit TNS/JDBC sections using the `--*-host` fallbacks with a warning.

### ✅ 2.5 Remote timeout without GNU `timeout`

**Problem:** `common/dg_local_status_common.sh:340-351` falls back to no timeout when `timeout` is absent (AIX default), so the wallet probe at `:418` can hang for the full TNS timeout.

**Change:** stop relying on the `timeout` binary for the connect probe: embed timeouts in the connect descriptor — append `(CONNECT_TIMEOUT=${REMOTE_TEST_TIMEOUT})(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=0)` to a `DESCRIPTION`-form connect string for the probe, or use `sqlplus -L` with `SQLNET.OUTBOUND_CONNECT_TIMEOUT` guidance. Keep the `timeout` fast-path when present.

**Verify:** point `PEER_TNS` at a non-routable IP (drops packets) and confirm the probe returns within ~REMOTE_TEST_TIMEOUT seconds on a box without `timeout`.

### ✅ 2.6 Small robustness fixes (one batch commit)

- `sql/queries/get_fsfo_status.sql:5`: add `SET PAGESIZE 0` (parsers in `fsfo/observer.sh:533` assume no blank lines).
- `common/dg_functions.sh:636`: `read password` → `read -r password` (backslash-safe; matches the fixed copies in `setup_dg_wallet.sh` and `dg_local_status_common.sh`).
- `common/dg_functions.sh:979,1017`: replace `eval "$result_var=..."` with `printf -v "$result_var" '%s' "$file"`.
- `common/dg_local_status_common.sh:1067`: guard `"${SUMMARY_ERRORS[@]}"` with `[[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]` (empty-array + `set -u` on bash ≤4.3).
- Shebang consistency: `dg_handoff.sh:1`, `common/dg_functions.sh:1` → `#!/usr/bin/env bash`.
- Temp files: replace fixed `/tmp/..._$$` names (`primary/04:133`, `standby/03:450`, `standby/05:371`, `common/dg_functions.sh:927`) with `${TMPDIR:-/tmp}` + `mktemp` where available (fallback: private 700 dir + `$$` name inside it), and add `trap 'rm -f "$tmp"' EXIT` cleanup. `dg_status.sh:140` mkdir fallback: `chmod 700`.

**Verify:** existing unit tests (`tests/test_add_sid_to_listener.sh` covers the listener temp-file path) + shellcheck pass on changed files.

---

## Workstream 3 — Security

### ✅ 3.1 Remove passwords from process argv

**Problem:** SYS/observer passwords visible in `ps -ef` for the duration of the call:
- `standby/05_clone_standby.sh:373-374`: `rman TARGET sys/${SYS_PASSWORD}@... AUXILIARY sys/${SYS_PASSWORD}@...`
- `common/dg_functions.sh:617` (`dgmgrl -silent "sys/pw@..."`), `:675` (`sqlplus -s "sys/pw@..."`)
- `common/setup_dg_wallet.sh:191,206`; `common/dg_local_status_common.sh:439→466` (every remote diag query)
- `fsfo/observer.sh:233,244` and `setup_dg_wallet.sh:328`: `mkstore -createCredential ... "$password"`

**Change:**
- sqlplus: `sqlplus -s /nolog` + `CONNECT sys/"pw"@tns AS SYSDBA` fed on stdin (works with the existing heredoc/cmdfile patterns; keep RMAN's cmdfile approach — move `connect target`/`connect auxiliary` lines *into* the cmdfile, chmod 600, delete after).
- dgmgrl: `dgmgrl /nolog` + `CONNECT sys/"pw"@tns` on stdin.
- mkstore: no stdin path exists for `-createCredential` — document the one-time exposure at setup; keep the exposure to the single setup moment and say so in the docs.
- Ensure no password ever appears in `LOG_FILE` output (`run_*` echo the command in verbose mode — mask it).

**Verify:** while step 5/diag runs, `ps -ef | grep -c 'sys/'` must be 0; E2E still passes.

### ✅ 3.2 NFS artifact cleanup script

**Problem:** `primary/01:528-534` and `primary/09:431-441` copy `orapw*` files (SYS hash) to the group-readable NFS share; nothing ever removes them. RMAN scripts/logs and pfiles also persist.

**Change:** new script `common/cleanup_nfs_artifacts.sh`:
- Lists what it will remove (password files, generated pfiles, RMAN cmdfiles/logs for a chosen `DB_UNIQUE_NAME`), keeps the config `.env` + handoff report by default.
- `--all` flag to remove everything for that build; confirmation prompt (reuse `select_config_file` + approval pattern from `dg_functions.sh`).
- Mention it as an optional final step in `CLAUDE.md` execution order and `docs/DATA_GUARD_WALKTHROUGH.md`; have step 10 print a reminder.
- Immediately mitigate: `chmod 600` the `orapw*` copies at creation time in steps 1 and 9.

**Verify:** run after E2E; assert no `orapw*` remains on the share; re-run walkthrough steps that read the share to confirm nothing needed was deleted.

### ✅ 3.3 Tighten NFS export and share permissions

**Problem:** `nfs/01_setup_nfs_server.sh:23`: `rw,sync,no_subtree_check,no_root_squash`; share created 775 (`:111-114`) and never chowned.

**Change:** drop `no_root_squash` (everything runs as oracle); `chown oracle:oinstall`, `chmod 750` on the share and subdirs (prompt for the owner user/group with oracle:oinstall default, since UIDs must match across hosts for NFS). Update the matching text in `docs/DATA_GUARD_WALKTHROUGH.md:75-76`.

**Verify:** re-run NFS setup + `nfs/02_mount_nfs_client.sh` on both hosts; oracle can read/write, others cannot; steps 1-2 still function.

### ✅ 3.4 Narrow the dedicated-user grant

**Problem:** `trigger/create_role_trigger_dedicated_user.sh:204,233` grants `EXECUTE ON DBMS_SYSTEM` only for alert-log writes (`KSDWRT`) — contradicts the least-privilege purpose.

**Change:** replace alert-log writes in the dedicated-user variant with a definer-rights logging procedure owned by SYS (created by the script, single-purpose: takes a VARCHAR2 and calls `SYS.DBMS_SYSTEM.KSDWRT(2, msg)`), grant EXECUTE on *that* to the dedicated user; drop the DBMS_SYSTEM grant. Document the trade-off in the script header.

**Verify:** deploy the variant, force a per-service failure (stop a PDB), confirm the message reaches the alert log and `SELECT ... FROM dba_tab_privs WHERE grantee='DG_ADMIN'` shows no DBMS_SYSTEM.

---

## Workstream 4 — UX / functionality

### ✅ 4.1 Monitoring-friendly exit codes for `dg_status.sh`

`dg_status.sh` computes ERRORS/WARNINGS but always exits 0. Mirror the 0/1/2 convention from `dg_local_status_common.sh:1536-1544` (`0` healthy, `1` warnings, `2` errors). Update `docs/DG_STATUS.md`. Fix the deprecated `dg_check_sid.sh` shim note: document that it forces exit 0 (keep behavior — it's the documented contract — but say so).

### ✅ 4.2 TTY-aware colors

No script guards color on `[ -t 1 ]`. Add a shared helper (in `dg_functions.sh` and `dg_local_status_common.sh`): enable color only when stdout is a tty and `NO_COLOR` is unset; add `--no-color` flag to `dg_status.sh`, `dg_triage_sid.sh`, `dg_diag_sid.sh`, `dg_handoff.sh`. `dg_functions.sh` already strips color for LOG_FILE — keep that.

**Verify:** `bash dg_status.sh | cat` shows no escape codes; interactive run unchanged.

### ✅ 4.3 Configurable thresholds

Hardcoded: FRA 80/90% (`dg_status.sh:614-618`, `dg_local_status_common.sh:837-841,917-921`), sequence-gap 1/5 (`:892-896`), and any-nonzero-lag=WARN (`:882-888`). Introduce env-overridable defaults in one place (`DG_FRA_WARN_PCT=80`, `DG_FRA_CRIT_PCT=90`, `DG_SEQ_GAP_WARN=1`, `DG_SEQ_GAP_CRIT=5`, `DG_LAG_WARN_SECONDS=60`); parse the `+HH:MM:SS` lag format into seconds for comparison. Document in `docs/DG_STATUS.md` / `docs/DG_CHECK.md`.

### ✅ 4.4 Deduplicate `dg_status.sh` against `dg_local_status_common.sh`

`dg_status.sh:112-233,478-491` re-implements ~400 lines of the common library (rendering helpers, status assessment, the awk alert-log filter — duplicated 4× within dg_status.sh alone — and the SQL column blocks). This is why the AIX grep bugs exist in two places.

**Change:** extract the genuinely shared pieces into a new `common/dg_render_common.sh` (pure functions only: `repeat_char`, `fit_text`, `wrap_text`, `row/header/subheader`, `status_icon`, `assess_*`, the awk log filter, the shared SQL SELECT lists as heredoc constants). Source it from both `dg_status.sh` and `dg_local_status_common.sh`. Do this *after* WS1.6 so the fixes land once. Keep `dg_status.sh` runnable from a jump host — it must only need `common/` files that exist in the repo checkout.

**Verify:** byte-compare dashboard output before/after on the same live config (modulo timestamps); E2E status phase.

### ✅ 4.5 Trigger scripts: self-discovery for the non-CDB variants

`trigger/create_role_trigger.sh` and `create_role_trigger_dedicated_user.sh` hard-require `standby_config_*.env` + NFS mount, but only use them for a filename label and service discovery the CDB variant already does from `V$DATABASE`/`V$ACTIVE_SERVICES`. Align: attempt self-discovery first (DB_UNIQUE_NAME from `V$DATABASE`), fall back to config file if present; write generated SQL to NFS when mounted, else to `$PWD` with a notice.

### ✅ 4.6 Small UX batch

- `primary/10_generate_handoff_report.sh:13,277,326`: replace "step 14" references with "the role-aware service trigger (`trigger/create_role_trigger.sh`)".
- Remove dead code: `LISTENER_PRIMARY_FILE` in `primary/04:131` (and stop generating `listener_primary_*.ora` in step 2 if truly unused — confirm first); `render_tns_single`/`render_jdbc_single` in `dg_handoff.sh:262-297`.
- `trigger/create_role_trigger_cdb.sh:579`: uppercase hand-entered container names before quoting (`ALTER SESSION SET CONTAINER = "MYPDB"`), or match case-insensitively against `V$CONTAINERS` and use the discovered exact name.
- Service-name validation regex (`create_role_trigger.sh:264`, `create_pdb_service.sh:123` etc.): `^[A-Za-z][A-Za-z0-9_.$]*$` (non-empty, leading alpha).
- Approval mode: print the active mode in each script's banner ("approval prompts: OFF (use -a to enable)") so the default is visible.
- Non-interactive safety: in prompts (`dg_local_status_common.sh:431-436`, `dg_functions.sh:435,657,1003,1033`), when `! [ -t 0 ]`, skip the prompt and take the safe default instead of blocking.

### ⏭️ 4.7 (Optional, discuss before building) JSON output mode

`--json` flag for `dg_triage_sid.sh` / `dg_status.sh` emitting a flat JSON object (role, modes, lag seconds, gaps, fra_pct, errors[], warnings[], exit_code) for monitoring ingestion. Pure printf-generated JSON (no jq dependency). Defer until 4.3/4.4 land.

### ✅ 4.8 Application-facing handoff report enhancements

**Problem:** The handoff report (`primary/10_generate_handoff_report.sh`, `dg_handoff.sh`) gives application teams connection strings but little of the information that actually determines how their application behaves against a Data Guard pair. It states facts a DBA cares about (apply lag, gaps) but not their application consequences (RPO, brownout duration, standby readability). The companion briefing `docs/DG_APPLICATION_IMPACT.html` covers the behavioral side but is generic and not linked from the generated report.

**Change — derive app-relevant facts from the live config and state them in application terms:**

- **Data-loss / RPO statement.** Read protection mode + per-member `LogXptMode` (broker `SHOW DATABASE`) and emit a plain-language line: SYNC/FASTSYNC + MaxAvailability → "a failover loses no committed transactions"; ASYNC/MaxPerformance → "a failover may lose the last few seconds of committed transactions — design idempotency/reconciliation accordingly." Also note the commit-latency implication of SYNC for chatty transaction patterns.
- **Expected outage behavior.** If FSFO is enabled, read `FastStartFailoverThreshold` and state: "automatic failover after ~Ns of primary unreachability; expect connection errors for roughly that window plus reconnect time." If FSFO is off: "failover is a manual DBA action; outage lasts until it is performed." Mention the post-role-change cold-cache brownout.
- **Standby readability.** Read the standby's `OPEN_MODE`. If `MOUNTED`, suppress (or clearly mark as unavailable) the standby-only connection strings — today they're emitted unconditionally and connecting to a mounted standby fails confusingly for an app user. If `READ ONLY WITH APPLY`, keep them but add the Active Data Guard licensing note, the apply-lag/read-your-writes caveat, and no-DML warning (ORA-16000).
- **Role-trigger detection instead of assumption.** Check whether `DG_SERVICE_MGR` (SYS or dedicated-user variant) actually exists and its triggers are ENABLED. If yes: state the role-aware descriptor is safe. If no: print a prominent warning that role-aware descriptors may connect apps to a read-only standby until the trigger (`trigger/create_role_trigger.sh`) is deployed. Replaces the current unconditional "when the step-14 trigger is deployed" wording (ties into 4.6's step-14 cleanup).
- **More connection formats per service** (apps aren't all JDBC): Easy Connect Plus with failover/timeout parameters (single line, no tnsnames needed, 19c+ clients), plus a short table mapping the same descriptor into ODP.NET / python-oracledb / SQLAlchemy DSN forms. Keep the existing TNS + JDBC blocks as-is.
- **Recommended client/pool settings section** (concrete values, not prose): `CONNECT_TIMEOUT`/`TRANSPORT_CONNECT_TIMEOUT`/`RETRY_COUNT` (already in the descriptor — explain them), driver-level connection/read timeouts, dead-connection detection (`SQLNET.EXPIRE_TIME` server-side is already set or not — report it; TCP keepalive client-side), pool validation-on-borrow, and a note on TAF scope (SELECT-only replay; in-flight DML still needs app retry — the report already hints at this, make it a checklist).
- **Firewall prerequisite check.** The report should state explicitly, as a checklist item, that the app tier must reach *both* hosts on the listener port before go-live, and include the two `tnsping`/`nc` commands to prove it (extend the existing "Quick Verification" section to test both hosts, not just the two aliases).
- **Link the behavioral briefing.** Commit `docs/DG_APPLICATION_IMPACT.html` to the repo (currently untracked), and have step 10 copy it next to the report on the NFS share (`dg_application_impact.html`) and reference it from the report's "Notes for Client Teams" section. Optionally add a condensed "What changes for your application" summary (5 bullets: commit latency, FORCE LOGGING vs NOLOGGING batch jobs, sequence gaps after role change, cold cache brownout, reach-both-hosts) directly in the Markdown so the report is self-contained even if the HTML isn't distributed.
- **Apply the same changes to `dg_handoff.sh`** (standalone variant) — it discovers topology live, so it can derive everything above from `V$DATABASE`, `V$DATAGUARD_CONFIG`, and `DGMGRL SHOW DATABASE VERBOSE`; where broker is down, degrade to "unknown" with a note (consistent with 2.4).

**Files:** `primary/10_generate_handoff_report.sh`, `dg_handoff.sh`, new `sql/queries/` snippets (standby open mode via broker/remote query, trigger-presence check, FSFO threshold), `docs/DG_APPLICATION_IMPACT.html` (commit), `CLAUDE.md` handoff section.

**Verify:** generate the report on the E2E pair in three states — (a) trigger deployed + FSFO on, (b) no trigger, (c) standby mounted — and assert the conditional sections render correctly in each; check the Easy Connect string actually connects from a client.

---

## ✅ Workstream 5 — Documentation

- Document the ADG caveat: the CDB trigger's stop-on-standby uses `DBMS_SCHEDULER.CREATE_JOB`, which cannot run on a read-only standby; the failure is swallowed into the alert log by design. Add to `trigger/create_role_trigger_cdb.sh` header + CLAUDE.md trigger section.
- Document the post-hardening re-clone limitation (SYS locked/randomized) and the recovery procedure (temporary unlock + password reset + password-file re-sync), referenced from step 5's restart instructions and step 8's output.
- Update `docs/DATA_GUARD_WALKTHROUGH.md` NFS export options (WS3.3) and add the cleanup script (WS3.2) as a final optional step.
- CLAUDE.md: add `common/cleanup_nfs_artifacts.sh` to project structure/execution order; note new threshold env vars.

---

## Workstream 6 — Test coverage

### ✅ 6.1 Unit tests for the WS1 shell fixes

New tests alongside the existing ones in `tests/`:
- `tests/test_df_parsing.sh` — feed captured Linux `df -Pk` and AIX-format `df -k` output through the extraction function (factor the parsing into a small function in step 3 or `dg_functions.sh` so it's testable).
- `tests/test_grep_portability.sh` — assert the broker-output patterns match/non-match against captured DGMGRL samples using POSIX-only grep flags; include a repo-wide sweep asserting no `\|`-in-BRE / `\s`-in-ERE / `grep -P` occurrences in `*.sh`.
- `tests/test_counter_increment.sh` — regression for the `((x++))`/`set -e` pattern (sweep: no `((VAR++))` in repo).
- `tests/test_sid_detection.sh` — feed pmon-line fixtures (normal, +ASM present, SSH error text) through the extraction logic.

### ⏭️ 6.2 E2E: switchover assertion for the role trigger

Extend `tests/e2e/run_e2e_test.sh` step 11: after deploying the trigger, perform `SWITCHOVER` via DGMGRL, assert via `V$ACTIVE_SERVICES` on both sides that the managed service moved (running on new primary, stopped on new standby), then switch back. Gate behind a flag (`SKIP_SWITCHOVER_TEST:-false`) since it doubles runtime.

### ✅ 6.3 E2E: observer lifecycle

Flip `SKIP_OBSERVER` default to `false` (after WS1.8 fixes the greps). Add assertions for `observer.sh start` → `status` (running) → `stop` (stopped, pidfile removed) → stale-pidfile handling (write bogus pidfile, expect `start` to succeed).

**Done 2026-07-07** — the full lifecycle (`setup` → `start` → `status` running → `stop` → stale-pidfile cleanup) ran live against the lab pair. It immediately surfaced the `fsfo/observer.sh` false-"Cannot connect" bug, which had gone unnoticed precisely because this phase was always skipped. See "E2E run 2026-07-07" below.

### ⏭️ 6.4 E2E: CDB variant trigger coverage

The CDB E2E config exists (`tests/e2e/` CDB variant). Add a phase that deploys `trigger/create_role_trigger_cdb.sh` + `create_pdb_service.sh`, asserts package validity, and (reusing 6.2) asserts a PDB service follows a switchover. Also run `create_role_trigger_dedicated_user.sh` in the non-CDB run and assert `DG_ADMIN` owns the objects and has no DBMS_SYSTEM grant (after WS3.4).

---

## Explicitly out of scope

- NFS-based config/state exchange (set in stone).
- AIX 7.2 support (set in stone — several fixes above exist to *preserve* it).
- ASM/RAC support, OMF redesign, listener/TNS architecture changes.
- `dg_check_sid.sh` behavior change (deprecated contract kept as-is, documented).

## Verification (overall)

1. ✅ The unit tests pass: `for t in tests/test_*.sh; do bash "$t"; done` (8 suites, all green). `shellcheck` was not available in the implementation environment — worth a one-off informational run where it is installed. `bash -n` passes on every `*.sh`.
2. ◐ Full E2E on the Linux test pair (non-CDB) — validated across **two independent lab runs** on the poug-dg1/poug-dg2 VirtualBox pair (both driven from the `dbmint` hypervisor):
   - **2026-07-07** — core pipeline (create_db + steps 1–7 + role trigger) GREEN, plus the **optional steps 8, 9, 10** (security hardening, FSFO, observer lifecycle) which had never been exercised before. See "E2E run 2026-07-07" below for the five product/harness bugs it surfaced.
   - **2026-07-17** — the asymmetric-layout run recorded in [`HANDOVER.md`](../HANDOVER.md); steps 1–7 + role trigger + cleanup against a standby remapped to a completely different base, producing the broker/SQL-error-handling fixes. It did **not** re-run steps 8–10, so the 2026-07-07 findings above remain the only live coverage of those.
   - Still not run: the **CDB variant** on either date.
3. ⬜ AIX spot checks (manual, on the real box): `df -Pk` columns, `command -v base64 timeout openssl`, the grep patterns against captured broker output, `ps -p PID -o args=` — **not run** (no AIX box in the implementation environment).
4. ◐ Security checks: static scan confirms no `sys/<password>` ever reaches a process argv (live `ps -ef` check during clone/diag still worth doing); NFS share perms 750/oracle:oinstall and the cleanup script's `orapw*` removal are implemented but **not yet verified against a live share**.

---

## E2E run 2026-07-07 (non-CDB, poug-dg1 / poug-dg2)

Ran the full non-CDB E2E against the live VirtualBox pair (run directly from the
hypervisor `dbmint`; DB hosts reachable as `oracle@dbmint:2201` / `:2202`).

**Result:** create_db + steps 1–7 + 11 **all green**; optional steps 8, 9, 10
validated after fixes. Five bugs surfaced and were fixed (3 product, 2 harness);
two environment prerequisites were discovered.

> **Relationship to the 2026-07-17 run.** This session ran on a symmetric layout and
> focused on the *optional* steps 8–10. The later run recorded in
> [`HANDOVER.md`](../HANDOVER.md) (merged to `main` @ `706c1a5`) covered the
> *asymmetric* layout for steps 1–7 and never re-ran 8–10. The two are
> complementary, not competing: only the harness's `\|`-under-ugrep fix was found
> by both, and that one landed upstream first. Everything else below — the two
> `08_security_hardening.sh` bugs, the `observer.sh` false-"Cannot connect", the
> jump-optional/`LOCAL_DEPLOY`/password-file-migration harness work, and the step-9
> input order — is unique to this run and was merged **after** the 2026-07-17 work.

### Product bugs found & fixed

- **`primary/08_security_hardening.sh` — SYS password 32 chars > Oracle's 30-char
  limit (`ORA-00972: identifier is too long`).** The WS1.5 generator used
  `cut -c1-32`; Oracle rejects passwords longer than 30. Changed both the openssl
  and `/dev/urandom` fallback paths to `cut -c1-30`. Without this, step 8 aborts on
  the very first `ALTER USER SYS IDENTIFIED BY`.
- **`primary/08_security_hardening.sh` — no password-file-format pre-check; SYS left
  changed-but-unlocked on `ORA-40365`.** Locking SYS needs a **format 12.2** password
  file; DBCA creates format 12. On a legacy file the script changed the SYS password
  first, then failed the lock — leaving SYS with an *unknown random password* and
  unlocked (dangerous if OS auth were unavailable). Added a pre-flight `orapwd
  describe` format check that stops **before** touching SYS, with the exact migration
  commands.
- **`fsfo/observer.sh` — `observer.sh start` always failed when FSFO is enabled
  (false "Cannot connect").** The connection check `grep -qiE "ORA-|error"` matched
  the literal word "Error" in the normal `show fast_start failover` output ("Oracle
  **Error** Conditions:", "Datafile Write **Error**s"). Narrowed to
  `grep -qE "ORA-[0-9]|TNS-[0-9]"`. This was never caught because the observer E2E
  (WS6.3) was always skipped.

### Harness bugs found & fixed (`tests/e2e/run_e2e_test.sh`)

- **`\|` alternation in `grep -E` never matched under `ugrep`.** The runner host's
  `grep` is `ugrep 7.5.0`, which (correctly) treats `\|` in ERE as a *literal* pipe,
  so `assert_dgmgrl` patterns like `SUCCESS\|enabled\|Enabled` never matched — step 6
  failed even though the broker was `SUCCESS`. Same class as WS1.6, but in the
  harness. Converted all six patterns to real ERE (`SUCCESS|enabled|Enabled`, …).
- **Step 9 piped-input order wrong** (`username, password, y`) vs the script's actual
  prompts (`username → proceed(y) → password → confirm`); the password was fed to the
  proceed prompt and FSFO was cancelled. Fixed the order. Also fixed the protection-mode
  assertion (`assert_sql` strips whitespace, so the expected must be `MAXIMUMAVAILABILITY`,
  not `MAXIMUM AVAILABILITY`).
- Added: optional ProxyJump (`JUMP_HOST=""` → connect DB hosts directly), a
  `LOCAL_DEPLOY=true` rsync deploy (test uncommitted fixes without pushing to origin),
  and a post-DBCA password-file migration to **format 12.2** in `create_db` so the
  optional step-8 phase works on a fresh DB.

### Environment prerequisites / notes (not code bugs)

- **Password-file format 12.2 is a hard prerequisite for step 8** (SYS lock). See the
  new pre-check + the create_db migration.
- **Refreshing the standby's password file requires the standby instance to re-read
  it.** After step 8 (SYS pw change) *and* step 9 (adds the observer SYSDG user to the
  primary's password file), redo transport failed with **ORA-16191** on reconnect even
  with byte-identical password files on both sides — until the standby instance was
  **restarted** to re-read the file. WS1.4's "stage to NFS + `cp` to standby" step
  should note that a running standby caches its password file; a copy alone is not
  enough. Final state after the restart: transport lag 0, config **SUCCESS**.
- Steps 9/10 lifecycle fully exercised: FSFO enabled (Zero Data Loss / FASTSYNC),
  observer setup → start → status(running) → stop → **stale-pidfile handling** (WS2.2:
  a live non-dgmgrl PID in the pidfile is detected as stale and cleaned).

### Still outstanding

*(As of the 2026-07-17 merge — the asymmetric-layout gap listed here originally has
since been closed by that run; see [`HANDOVER.md`](../HANDOVER.md).)*

- CDB-variant E2E (`run_e2e_test_cdb.sh`) + the CDB trigger coverage (WS6.4), including
  the asymmetric layout against real PDBs / GUID dirs.
- Switchover assertion for the role trigger (WS6.2).
- OMF-primary → Traditional-standby.
- AIX spot checks (no AIX box).
- **Pre-existing, unrelated:** the host's own `cdb1 → cdb1_stby` Data Guard config
  (`my_dg_config`) has **Redo Apply stopped on `cdb1_stby`** (`ORA-16766`, ~4.5h apply
  lag) — present before this session and not touched. Restart MRP on `cdb1_stby` to
  clear it.

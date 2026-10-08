# E2E runbook for Claude

The user wants the E2E suite **executed** against the real lab, not designed
and handed off: run it, read the failures, fix the scripts, re-run until green.
The suite itself is described in `README.md` (same directory); this file is
the operating knowledge around it.

## The lab

libvirt VMs on the hypervisor `dbmint` (`virsh -c qemu:///system`):
`ol9_19_dg1` (primary, 192.168.122.193), `ol9_19_dg2` (standby, .194),
`ol9_19_dg3` (third host, .195). They do not autostart; start dg2, dg3, then
dg1. The 192.168.122.x leases can change - check with
`virsh -c qemu:///system domifaddr ol9_19_dg1` before trusting `config.env`.
Two networks: 192.168.122.x (ssh from dbmint) and 192.168.56.x (what the VMs
call each other: `ol9-19-dg1/2/3`, NFS, redo transport) - never mix them.

Running **on dbmint**: `JUMP_HOST=""` (direct ssh to `oracle@192.168.122.x`).
From the Mac: `JUMP_HOST="dbmint"`, `JUMP_USER="db"`. The committed
`config.env` is the dbmint form; do not commit a Mac-only variant.

`cdb1` (dg1) -> `cdb1_stby` (dg2) with its observer `dg_observer` on dg3 is a
**persistent fixture** - leave it alone. The suite never touches the shared
`network/admin` except in s01 (which only appends/removes its own blocks) and
never kills an observer it did not start. The VMs have 4 GB: the doctor's
`mem1g`/`mem2g` gate skips CDB scenarios when `cdb1` leaves too little.

## Running

```bash
bash tests/e2e/e2e.sh doctor                     # always first after booting the lab
bash tests/e2e/e2e.sh run --tier smoke            # s01 + r03, ~40 min
bash tests/e2e/e2e.sh run --scenario s05          # one scenario
bash tests/e2e/e2e.sh run --scenario s02 --from-step step5   # resume after a fix (DBs still up)
bash tests/e2e/e2e.sh clean --scenario s02        # tear down a kept/failed scenario
bash tests/test_e2e_harness.sh                    # offline checks of the harness itself
```

Always `bash`, never `zsh` (word splitting of `SSH_OPTS`). `LOCAL_DEPLOY=true`
rsyncs the working tree to `REPO_DIR` on every host at the start of a run, so
uncommitted fixes are tested without pushing. DBCA takes 5-10 minutes per
scenario; run campaigns in the background with a long timeout.

## The loop

1. Read `logs/<run>/<scenario>/results.log` - the first `[FAIL]` is the one
   that matters; the rest usually follows from it.
2. `build/stepN.out` is what the script printed; `build/stepN.tty` has the
   `[prompt] ... => ...` records. `UNANSWERED PROMPT: <text>` means the script
   asked something no rule foresaw: add the rule to `answers/stepN.rules`
   (and a `WANT_*` key if the answer is scenario-specific).
3. `provision/shape.txt` shows what the primary really looked like; a `shape:`
   FAIL is a provisioner problem, not a script problem.
4. Fix, then `run --scenario ID --from-step stepN` (databases are kept on
   failure) or `clean` + full re-run when the state is suspect.
5. A finding about the scripts goes into the script, a test with it, and
   `docs/`; a finding about the harness goes into `lib/`, `checks/`, `proofs/`.

## Knowledge that still bites

- When a run is driven from Claude Code's Bash tool, `grep` is an exported
  shell *function* wrapping its bundled `ugrep` (that was the "dbmint grep is
  ugrep" of earlier notes - dbmint's own grep is GNU 3.11). ugrep differs on
  `\|`, `\+` and even `[+]+`; `lib/common.sh` unsets those functions so the
  runner and every tool it starts use the real binary. Keep real ERE
  alternation anyway.
- `select_config_file` auto-selects when exactly one `standby_config_*.env`
  exists; the runner wipes the share's generated files before provisioning
  so no menu ever appears (the `common.rules` menu rule is a safety net).
- After step 9 the standby's password file is replaced; the observer user
  reaches it through the second `ALTER USER ... IDENTIFIED BY` (F15). A
  standby-side `ORA-01017` for the observer means that path regressed.
- The observer wallet directory defaults to `$(dg_net_admin_dir)/wallet`; in
  scratch mode that is under `LAB_SCRATCH/net_<id>`, never the shared one (on
  some labs the shared one holds a TDE keystore).
- `_verify.sh` and the wallet scripts need a TTY for passwords on some paths;
  the driver provides one. Piped stdin (`ssh_piped` of the old runner) no
  longer exists anywhere in the harness.
- Memory: a CDB profile raises DBCA `totalMemory` to 1536 MB; with `cdb1`
  up on both VMs the doctor may skip the CDB scenarios - stop `cdb1`/`cdb1_stby`
  for a full-tier campaign and start them again afterwards.

## History

- 2026-10-07: suite redesigned (this runner). The previous fixed-stdin runners
  `run_e2e_test.sh` / `run_e2e_test_cdb.sh` are retired once s01 and s04 are
  green here; their last green run was 2026-10-03 on `1f44177` (70 passed).
- See `docs/HANDOFF_2026-10-03.md` for the lab state and F15 at that time.

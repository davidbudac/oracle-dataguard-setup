# Data Guard Setup — Improvements

## Standby redo/datafile directory creation (redo on a separate mount)

### Problem
When a primary's **online redo logs (and/or datafiles) live on a separate mount
whose path does not contain the DB-unique-name token**, the standby setup failed:

- Step 5 (`05_clone_standby.sh`) RMAN `DUPLICATE` / MRP aborted with
  `ORA-17502` / `ORA-19504` ("failed to create file") because the standby redo
  directory had never been created on the standby host.

### Root cause
- `primary/02_generate_standby_config.sh` derives the standby paths
  (`STANDBY_DATA_PATHS` / `STANDBY_REDO_PATHS`) by detecting the DB-name **token
  in the datafile path** and substituting primary → standby across *all* paths.
- A redo (or data) directory on a separate mount with no token comes back
  **unchanged**, silently pointing the standby at the primary's path. It then
  never reliably lands in the directory list that `standby/03_setup_standby_env.sh`
  creates.
- The `STANDBY_*_PATHS` arrays were a *derived* view. The authoritative record
  of where Oracle actually places files is `LOG_FILE_NAME_CONVERT` /
  `DB_FILE_NAME_CONVERT`.

### Fix — Part 1: authoritative directory creation (`standby/03_setup_standby_env.sh`)
- Added `add_convert_standby_dirs()` which parses the **standby side of every
  `LOG_FILE_NAME_CONVERT` and `DB_FILE_NAME_CONVERT` pair** and adds each to
  `DIRS_TO_CREATE`. These are the exact path prefixes RMAN writes to, so every
  redo/data directory is guaranteed to exist regardless of how step 2 derived
  (or failed to derive) the path.
- Also explicitly covers the `control_files` directory (`STANDBY_DATA_PATH`).
- Deduplicates `DIRS_TO_CREATE`, collapsing overlaps and trailing-slash variants
  (`/x` vs `/x/`) so the approval prompt and creation log show each directory once.

### Fix — Part 2: prompt for unmapped paths (`primary/02_generate_standby_config.sh`)
- Added `_confirm_unmapped_paths()` which runs right after the token substitution.
  For each datafile/redo directory where substitution produced **no change**
  (path lacked the token), it warns and prompts for the standby directory,
  defaulting to the identical path.
  - Symmetric mount layout → single Enter (preserves prior behavior).
  - Asymmetric standby redo mount → operator enters the correct path here instead
    of hand-editing the config.
- Runs **before** the `*_FILE_NAME_CONVERT` pairs are built, so the corrected path
  flows into the convert, the SRL defaults, and the saved config automatically.
- Uses `eval`-based array indirection for bash 3.2 / AIX compatibility.

### Safety / regression notes
- `bash -n` passes on both scripts.
- The E2E layout (`oradata/dgnonc…`) contains the token, so substitution changes
  the paths → no new prompt fires → the piped-stdin E2E test is unaffected.
- For an already-generated `standby_config_*.env`, the step-2 prompt only fires on
  a fresh generate; edit the redo path and run `02_…sh --regenerate`. The step-3
  fix helps either way.

### Validation status
- [x] Unit-level logic tested in isolation (convert parsing, dedup, override,
      accept-default).
- [ ] Full E2E run against real Oracle hosts (`bash ./tests/e2e/run_e2e_test.sh`)
      — recommended before relying on this in production.

## Future improvements (not yet done)
- Consider normalizing the trailing-slash asymmetry at the source:
  `sql/queries/get_redo_log_paths.sql` keeps the trailing slash while
  `get_datafile_dirs.sql` strips it. Making them consistent would simplify
  downstream path handling and dedup.
- Consider per-path token detection in step 2 (detect the token in each redo path
  independently) so case-mismatched tokens (e.g. `dgnonc` vs `DGNONC`) remap
  correctly without operator intervention.
- Guard against substring corruption in the global `sed` substitution when the
  DB-name token also appears as a substring of a mount name.

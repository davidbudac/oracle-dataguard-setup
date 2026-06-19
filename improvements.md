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

## Path normalization & per-path token remapping

### Fix — Part 3: one no-trailing-slash convention at the source
- `sql/queries/get_redo_log_paths.sql` and `sql/queries/get_redo_member_path.sql`
  now strip the trailing slash (`INSTR(MEMBER,'/',-1)-1`), matching
  `get_datafile_dirs.sql`. Every directory path — datafile, online redo, and SRL —
  now shares a single **no-trailing-slash** convention.
  - This direction is forced by `${STANDBY_DATA_PATH}/control01.ctl` (the pfile and
    RMAN `SET CONTROL_FILES` lines): datafile dirs *must* be slash-less, so redo
    dirs were aligned to them rather than the reverse.
  - All redo-member concatenation sites already re-add the slash before appending a
    filename (`primary/04_prepare_primary_dg.sh:266`, `dg_check_srl.sh:175`), so
    no-slash input is safe. `*_FILE_NAME_CONVERT` prefix-matches correctly either
    way because the separator slash is part of the unmatched suffix.
  - Step 2's separate-SRL branch now *strips* a trailing slash instead of adding
    one, so SRL paths follow the same convention.
  - Bonus: a redo directory that names the same directory as a datafile directory
    is now byte-identical to it, so the convert-pair dedup collapses it naturally
    (see `tests/test_file_name_convert.sh` Test 4) instead of carrying a
    near-duplicate `…/X` vs `…/X/` pair.

### Fix — Part 4: per-path, case-aware, substring-safe token remapping
- `primary/02_generate_standby_config.sh` replaces the previous single-token
  detection (which keyed off the first datafile path only and applied that one
  token to every path via an unbounded `sed s/tok/rep/g`) with three small helpers:
  `_path_has_component`, `_replace_path_component`, and `remap_path_token`.
- **Per-path detection** (was: future item #2): each datafile/redo directory is
  remapped on its own, detecting whichever case variant of `DB_UNIQUE_NAME`
  (`UPPER`, `lower`, or the literal mixed case) appears in *that* path. A datafile
  mount using `…/DGNONC` and a redo mount using `…/dgnonc` now both remap, instead
  of the case-mismatched one silently falling through to the operator prompt.
  Case is preserved per path (an uppercase primary dir → uppercase standby dir).
- **Substring guard** (was: future item #3): replacement is bounded to whole,
  slash-delimited path *components*, so a token that also appears as a substring of
  a mount name (e.g. `/DGNONCDATA/` when the token is `DGNONC`) is never corrupted.
  A path that contains the token only as a substring is left unchanged and surfaced
  by the existing `_confirm_unmapped_paths` prompt rather than being mis-mapped.
- Portable to AIX / bash 3.2: component matching uses `case` globbing and two
  plain `sed` passes (interior `/tok/`, then a trailing `/tok` at end of string) —
  no GNU regex alternation.

### Validation status (Parts 3 & 4)
- [x] `bash -n` passes on all changed scripts.
- [x] `tests/test_path_token_remap.sh` (new) — 10 cases: case-mismatch remap,
      substring guard, whole-component replacement, token-less passthrough,
      trailing-slash compatibility, and mixed-case variants.
- [x] `tests/test_file_name_convert.sh` updated to the no-trailing-slash convention
      (Test 4 now demonstrates the dedup collapse) — passes.
- [x] `tests/test_add_sid_to_listener.sh` still passes (unaffected regression check).
- [x] Read-only check against a live 19c DB (`cdb1`): the updated redo queries
      return no-trailing-slash paths (`/u01/oradata/CDB1`, `/u01/oradata/CDB1/onlinelog`)
      that now match `get_datafile_dirs.sql` byte-for-byte, so a redo dir coinciding
      with a datafile dir collapses in the convert-pair dedup.
- [x] E2E layout safety: the test uses `db_unique_name=dgnonc` with
      `oradata/dgnonc` (lowercase token present as a path component), so per-path
      remapping still produces a change → no new prompt → piped-stdin E2E
      unaffected.
- [ ] Full E2E run against real Oracle hosts — recommended before production,
      especially a layout with redo on a separate, token-less or case-mismatched
      mount.

## Future improvements (not yet done)
- The FRA/archive default derivations in step 2 (`db_recovery_file_dest`,
  `PRIMARY_ARCHIVE_DEST`) and the step-3 `STANDBY_FRA_CALC` fallback still use a
  simple token `sed`. The step-2 FRA derivation is already component-bounded
  (`/${DB_UNIQUE_NAME}/`), but the step-3 fallback is not — it could reuse
  `remap_path_token` for full substring safety.
- Oracle's `*_FILE_NAME_CONVERT` does literal prefix matching with no component
  boundary, so two sibling directories where one DB-name dir is a strict prefix of
  another (e.g. `/redo/DGNONC` and `/redo/DGNONC2`) could in theory cross-match.
  This pre-existing exposure also applies to datafile dirs and is not specific to
  the redo change; mitigation would require keeping trailing slashes in the convert
  pairs, which conflicts with the control-file concatenation. Documented as a known
  tradeoff.

-- Get the SMALLEST standby redo log size and the LARGEST online redo log
-- size, both in exact BYTES, as "min_srl_bytes|max_orl_bytes". Used to
-- detect pre-existing SRLs that are undersized relative to the online redo
-- logs (count alone does not catch this) - see M6 in
-- docs/REVIEW_2026-08-05.md. Bytes, not rounded MiB: two figures rounded up
-- to MiB can read equal while the SRL is still smaller than the ORL, and
-- Oracle skips an SRL smaller by even one byte. TO_CHAR keeps a wide NUMBER
-- out of SQL*Plus scientific notation (NUMWIDTH 10).
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT (SELECT TO_CHAR(MIN(BYTES)) FROM V$STANDBY_LOG) || '|' ||
       (SELECT TO_CHAR(MAX(BYTES)) FROM V$LOG)
FROM DUAL;
EXIT;

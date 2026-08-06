-- Get the SMALLEST standby redo log size in MB. Used to detect
-- pre-existing SRLs that are undersized relative to the online redo
-- log size (count alone does not catch this) - see M6 in
-- docs/REVIEW_2026-08-05.md.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CEIL(MIN(BYTES)/1024/1024) FROM V$STANDBY_LOG;
EXIT;

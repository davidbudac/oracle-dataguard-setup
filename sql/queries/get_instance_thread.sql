-- Get the local instance's redo thread number (single-instance: normally 1).
-- Used when creating standby redo logs: SRLs added WITHOUT a THREAD clause
-- sit at THREAD#=0 until first use, which DGMGRL VALIDATE DATABASE reports
-- as "standby redo logs not configured for thread N" and blocks step 13's
-- MAXIMUM AVAILABILITY preflight even though the SRLs exist.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT THREAD# FROM V$INSTANCE;
EXIT;

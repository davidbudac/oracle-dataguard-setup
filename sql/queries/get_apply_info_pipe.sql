-- Get apply info as pipe-delimited string (for parsing)
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF LINESIZE 200
-- Last applied: APPLIED is 'IN-MEMORY' (or still 'NO') for redo applied in
-- real time from the standby redo logs until the next checkpoint, so 'YES'
-- alone under-counts; MRP0's current sequence - 1 is the authoritative floor.
SELECT
    GREATEST(NVL(MAX(CASE WHEN a.APPLIED IN ('YES','IN-MEMORY') THEN a.SEQUENCE# END), 0),
             NVL(MAX(m.MRP_PREV), 0)) || '|' ||
    NVL(MAX(a.SEQUENCE#), 0)
FROM V$ARCHIVED_LOG a,
     (SELECT MAX(SEQUENCE#) - 1 AS MRP_PREV FROM V$MANAGED_STANDBY WHERE PROCESS = 'MRP0' AND SEQUENCE# > 0) m
WHERE a.THREAD# = 1;
EXIT;

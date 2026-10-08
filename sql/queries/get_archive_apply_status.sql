-- Get archive log apply status (with headers for display)
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET LINESIZE 150 PAGESIZE 50
-- 'IN-MEMORY' = applied in real time from the standby redo logs, not yet
-- checkpointed; counting only 'YES' under-reports the applied sequence.
SELECT THREAD#, MAX(SEQUENCE#) AS LAST_APPLIED
FROM V$ARCHIVED_LOG
WHERE APPLIED IN ('YES', 'IN-MEMORY')
GROUP BY THREAD#;
EXIT;

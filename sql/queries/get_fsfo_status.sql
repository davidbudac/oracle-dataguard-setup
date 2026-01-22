-- ============================================================
-- Get Fast-Start Failover status from V$DATABASE
-- Returns: FS_FAILOVER_STATUS|FS_FAILOVER_OBSERVER_PRESENT|FS_FAILOVER_OBSERVER_HOST
-- ============================================================
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT FS_FAILOVER_STATUS || '|' || FS_FAILOVER_OBSERVER_PRESENT || '|' || FS_FAILOVER_OBSERVER_HOST
FROM V$DATABASE;
EXIT;

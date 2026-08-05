-- Archived logs currently present on local disk, as a single
-- pipe-delimited line:
--   logs_on_disk|mb_on_disk|mb_in_fra|oldest_seq|newest_seq|oldest_time|newest_time
--
-- DELETED='NO' AND STATUS='A' restricts this to logs that still exist;
-- V$ARCHIVED_LOG keeps rows for deleted logs until they age out of the
-- control file. Rows are NOT de-duplicated by sequence here: a log
-- written to two local destinations really does occupy disk twice.
-- Timestamps use YYYY-MM-DD_HH24:MI so the fields carry no spaces.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 400 PAGESIZE 0 TRIMSPOOL ON
SELECT TO_CHAR(COUNT(*), 'FM99999999990') || '|' ||
       TO_CHAR(NVL(ROUND(SUM(blocks * block_size) / 1024 / 1024), 0), 'FM99999999990') || '|' ||
       TO_CHAR(NVL(ROUND(SUM(CASE WHEN is_recovery_dest_file = 'YES'
                                  THEN blocks * block_size ELSE 0 END) / 1024 / 1024), 0),
               'FM99999999990') || '|' ||
       TO_CHAR(NVL(MIN(sequence#), 0), 'FM99999999990') || '|' ||
       TO_CHAR(NVL(MAX(sequence#), 0), 'FM99999999990') || '|' ||
       NVL(TO_CHAR(MIN(first_time), 'YYYY-MM-DD"_"HH24:MI'), 'n/a') || '|' ||
       NVL(TO_CHAR(MAX(next_time), 'YYYY-MM-DD"_"HH24:MI'), 'n/a')
FROM   v$archived_log
WHERE  standby_dest = 'NO'
AND    deleted = 'NO'
AND    status = 'A';
EXIT;

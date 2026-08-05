-- Daily redo generation for the last 14 days (with headers for display).
-- PEAK_HR_MB / PEAK_HR_LOGS are the busiest single hour within that day,
-- which is what the redo transport has to keep up with - the daily
-- average hides bursts (batch windows, reorgs, index rebuilds).
-- See get_redo_stats_pipe.sql for the de-duplication rationale.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 100
COLUMN "DAY"          FORMAT A12
COLUMN "LOGS"         FORMAT 999999
COLUMN "REDO_MB"      FORMAT 99999999
COLUMN "REDO_GB"      FORMAT 999990.99
COLUMN "AVG_MB_LOG"   FORMAT 9999999
COLUMN "PEAK_HR_MB"   FORMAT 99999999
COLUMN "PEAK_HR_LOGS" FORMAT 999999
WITH logs AS (
    SELECT thread#, sequence#, resetlogs_id,
           MIN(first_time)          AS first_time,
           MAX(blocks * block_size) AS bytes
    FROM   v$archived_log
    WHERE  standby_dest = 'NO'
    AND    first_time >= TRUNC(SYSDATE) - 13
    GROUP  BY thread#, sequence#, resetlogs_id
),
hourly AS (
    SELECT TRUNC(first_time, 'HH24') AS hr,
           SUM(bytes)                AS bytes,
           COUNT(*)                  AS switches
    FROM   logs
    GROUP  BY TRUNC(first_time, 'HH24')
)
SELECT TO_CHAR(TRUNC(hr), 'YYYY-MM-DD')        AS "DAY",
       SUM(switches)                           AS "LOGS",
       ROUND(SUM(bytes) / 1024 / 1024)         AS "REDO_MB",
       ROUND(SUM(bytes) / 1024 / 1024 / 1024, 2) AS "REDO_GB",
       ROUND(SUM(bytes) / 1024 / 1024 / SUM(switches)) AS "AVG_MB_LOG",
       ROUND(MAX(bytes) / 1024 / 1024)         AS "PEAK_HR_MB",
       MAX(switches)                           AS "PEAK_HR_LOGS"
FROM   hourly
GROUP  BY TRUNC(hr)
ORDER  BY 1;
EXIT;

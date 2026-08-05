-- Redo generation statistics from V$ARCHIVED_LOG (last 30 days), as a
-- single pipe-delimited line:
--   span_days|log_count|total_mb|avg_mb_day|peak_mb_day|peak_day|
--   avg_mb_hour|peak_mb_hour|peak_hour|avg_switches_day|peak_switches_hour
--
-- Notes:
--   * Rows are de-duplicated by (THREAD#, SEQUENCE#, RESETLOGS_ID): one
--     archived log has one row per destination, so a plain SUM() would
--     multiply the redo volume by the number of local destinations.
--   * STANDBY_DEST='NO' excludes logs shipped to a standby (re-runs after
--     a Data Guard config already exists).
--   * A log's whole volume is attributed to the hour its FIRST_TIME falls
--     in - the usual approximation for redo rate reporting.
--   * The visible history is bounded by CONTROL_FILE_RECORD_KEEP_TIME
--     (7 days by default), so span_days reports the window actually seen.
--   * No rows (fresh database) yields zeros with span_days=0.04 (1 hour),
--     never a divide-by-zero.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 400 PAGESIZE 0 TRIMSPOOL ON
WITH logs AS (
    SELECT thread#, sequence#, resetlogs_id,
           MIN(first_time)          AS first_time,
           MAX(blocks * block_size) AS bytes
    FROM   v$archived_log
    WHERE  standby_dest = 'NO'
    AND    first_time >= SYSDATE - 30
    GROUP  BY thread#, sequence#, resetlogs_id
),
hourly AS (
    SELECT TRUNC(first_time, 'HH24') AS hr,
           SUM(bytes) / 1024 / 1024  AS mb,
           COUNT(*)                  AS switches
    FROM   logs
    GROUP  BY TRUNC(first_time, 'HH24')
),
daily AS (
    SELECT TRUNC(hr)     AS dy,
           SUM(mb)       AS mb,
           SUM(switches) AS switches
    FROM   hourly
    GROUP  BY TRUNC(hr)
),
span AS (
    SELECT COUNT(*)                     AS log_count,
           NVL(SUM(bytes) / 1024 / 1024, 0) AS total_mb,
           GREATEST(NVL(MAX(first_time) - MIN(first_time), 0), 1 / 24) AS span_days
    FROM   logs
)
SELECT TO_CHAR(ROUND(s.span_days, 2), 'FM99990.00') || '|' ||
       TO_CHAR(s.log_count, 'FM99999999990') || '|' ||
       TO_CHAR(ROUND(s.total_mb), 'FM99999999990') || '|' ||
       TO_CHAR(ROUND(s.total_mb / s.span_days), 'FM99999999990') || '|' ||
       TO_CHAR(NVL((SELECT ROUND(MAX(mb)) FROM daily), 0), 'FM99999999990') || '|' ||
       NVL((SELECT TO_CHAR(MAX(dy) KEEP (DENSE_RANK LAST ORDER BY mb), 'YYYY-MM-DD')
            FROM daily), 'n/a') || '|' ||
       TO_CHAR(ROUND(s.total_mb / (s.span_days * 24)), 'FM99999999990') || '|' ||
       TO_CHAR(NVL((SELECT ROUND(MAX(mb)) FROM hourly), 0), 'FM99999999990') || '|' ||
       NVL((SELECT TO_CHAR(MAX(hr) KEEP (DENSE_RANK LAST ORDER BY mb), 'YYYY-MM-DD"_"HH24"h"')
            FROM hourly), 'n/a') || '|' ||
       TO_CHAR(ROUND(s.log_count / s.span_days), 'FM99999999990') || '|' ||
       TO_CHAR(NVL((SELECT MAX(switches) FROM hourly), 0), 'FM99999999990')
FROM   span s;
EXIT;

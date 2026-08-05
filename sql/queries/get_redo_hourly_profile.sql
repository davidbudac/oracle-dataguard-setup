-- Redo generation profile by hour of day over the last 7 days (with
-- headers for display). Shows when the redo transport is under load.
--
-- AVG_MB is the average redo produced in that clock hour per day of the
-- window - the divisor is the number of distinct days seen, not the
-- number of hour buckets, so quiet hours are not flattered by simply
-- having no rows. PEAK_MB is the worst single occurrence of that hour.
-- See get_redo_stats_pipe.sql for the de-duplication rationale.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 100
COLUMN "HOUR"         FORMAT A6
COLUMN "AVG_MB"       FORMAT 99999999
COLUMN "PEAK_MB"      FORMAT 99999999
COLUMN "AVG_LOGS"     FORMAT 9990.9
COLUMN "PEAK_LOGS"    FORMAT 999999
WITH logs AS (
    SELECT thread#, sequence#, resetlogs_id,
           MIN(first_time)          AS first_time,
           MAX(blocks * block_size) AS bytes
    FROM   v$archived_log
    WHERE  standby_dest = 'NO'
    AND    first_time >= TRUNC(SYSDATE) - 6
    GROUP  BY thread#, sequence#, resetlogs_id
),
hourly AS (
    SELECT TRUNC(first_time, 'HH24') AS hr,
           SUM(bytes) / 1024 / 1024  AS mb,
           COUNT(*)                  AS switches
    FROM   logs
    GROUP  BY TRUNC(first_time, 'HH24')
),
win AS (
    SELECT GREATEST(COUNT(DISTINCT TRUNC(hr)), 1) AS days FROM hourly
)
SELECT TO_CHAR(hr, 'HH24') || ':00'                     AS "HOUR",
       ROUND(SUM(mb) / (SELECT days FROM win))          AS "AVG_MB",
       ROUND(MAX(mb))                                   AS "PEAK_MB",
       ROUND(SUM(switches) / (SELECT days FROM win), 1) AS "AVG_LOGS",
       MAX(switches)                                    AS "PEAK_LOGS"
FROM   hourly
GROUP  BY TO_CHAR(hr, 'HH24')
ORDER  BY 1;
EXIT;

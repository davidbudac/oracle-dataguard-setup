-- Get the redo log disk footprint the standby needs, in MB:
--   * online redo logs: BYTES * MEMBERS per group (V$LOG.BYTES is the size of
--     ONE member, so a plain SUM(BYTES) undercounts multiplexed groups)
--   * standby redo logs: what V$STANDBY_LOG already holds, or - when none exist
--     yet - the (groups + 1) groups of the largest ORL size that step 4 creates
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT ROUND(o.orl_mb + CASE WHEN s.srl_mb > 0 THEN s.srl_mb
                             ELSE (o.grp + 1) * o.max_mb END)
FROM   (SELECT NVL(SUM(BYTES * MEMBERS), 0) / 1024 / 1024 AS orl_mb,
               COUNT(*)                                   AS grp,
               NVL(MAX(BYTES), 0) / 1024 / 1024           AS max_mb
        FROM   V$LOG) o,
       (SELECT NVL(SUM(BYTES), 0) / 1024 / 1024 AS srl_mb
        FROM   V$STANDBY_LOG) s;
EXIT;

-- Redo generated since instance startup, as a single pipe-delimited line:
--   redo_mb|uptime_hours|mb_per_hour
--
-- Fallback for databases whose V$ARCHIVED_LOG history is too short to be
-- meaningful (freshly created or freshly restarted instances). Covers redo
-- generated, not redo archived, so it includes the current online log.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 200 PAGESIZE 0 TRIMSPOOL ON
SELECT TO_CHAR(ROUND(s.value / 1024 / 1024), 'FM99999999990') || '|' ||
       TO_CHAR(ROUND((SYSDATE - i.startup_time) * 24, 2), 'FM99990.00') || '|' ||
       TO_CHAR(ROUND((s.value / 1024 / 1024) /
                     GREATEST((SYSDATE - i.startup_time) * 24, 1 / 60)),
               'FM99999999990')
FROM   v$sysstat s, v$instance i
WHERE  s.name = 'redo size';
EXIT;

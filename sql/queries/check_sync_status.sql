-- ============================================================
-- Check Data Guard synchronization status
-- Returns transport lag and apply lag from V$DATAGUARD_STATS
-- Format: NAME|VALUE|UNIT (pipe-delimited)
-- ============================================================
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT NAME || '|' || VALUE || '|' || UNIT
FROM V$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag');
EXIT;

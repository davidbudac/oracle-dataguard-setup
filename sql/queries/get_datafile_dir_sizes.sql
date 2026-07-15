-- Get per-directory size in MB (datafiles + tempfiles), one line per
-- directory as <dir>|<size_mb>, for per-mount disk space checks.
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 400 PAGESIZE 0 TRIMSPOOL ON
SELECT DIR || '|' || CEIL(SUM(BYTES)/1024/1024)
FROM (
    SELECT SUBSTR(NAME, 1, INSTR(NAME, '/', -1)-1) AS DIR, BYTES FROM V$DATAFILE
    UNION ALL
    SELECT SUBSTR(NAME, 1, INSTR(NAME, '/', -1)-1) AS DIR, BYTES FROM V$TEMPFILE
)
GROUP BY DIR
ORDER BY 1;
EXIT;

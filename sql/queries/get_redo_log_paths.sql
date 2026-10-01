-- Get distinct redo log directories (WITHOUT the trailing slash, to
-- match get_datafile_dirs.sql so all directory paths share one
-- no-trailing-slash convention downstream). Online redo logs only (standby
-- redo logs often live in their own directory and must not be picked as the
-- "first" redo directory) and ORDER BY so that first entry is deterministic.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT DISTINCT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)-1) AS PATH
FROM   V$LOGFILE
WHERE  TYPE = 'ONLINE'
ORDER  BY 1;
EXIT;

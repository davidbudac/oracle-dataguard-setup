-- Get distinct redo log directories (WITHOUT the trailing slash, to
-- match get_datafile_dirs.sql so all directory paths share one
-- no-trailing-slash convention downstream).
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT DISTINCT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)-1) AS PATH FROM V$LOGFILE;
EXIT;

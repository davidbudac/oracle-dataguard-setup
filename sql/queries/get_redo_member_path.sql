-- Get directory of first redo log member (WITHOUT trailing slash, to
-- match the no-trailing-slash convention; callers re-add the slash
-- before concatenating a member filename).
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)-1) FROM V$LOGFILE WHERE ROWNUM=1;
EXIT;

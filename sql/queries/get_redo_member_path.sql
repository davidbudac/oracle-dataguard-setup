-- Get directory of the first ONLINE redo log member (WITHOUT trailing
-- slash, to match the no-trailing-slash convention; callers re-add the
-- slash before concatenating a member filename). TYPE='ONLINE' keeps a
-- standby redo log member from being picked; the ORDER BY makes "first"
-- deterministic. Empty output = no ONLINE member found (callers must
-- treat that as an error, not as "/").
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)-1)
FROM (SELECT MEMBER FROM V$LOGFILE WHERE TYPE='ONLINE' ORDER BY GROUP#, MEMBER)
WHERE ROWNUM=1;
EXIT;

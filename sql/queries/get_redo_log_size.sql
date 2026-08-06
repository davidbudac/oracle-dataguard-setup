-- Get the LARGEST online redo log size in MB. Standby redo logs must be
-- sized to the largest online redo log - Oracle refuses to use an SRL
-- smaller than that, and previously this query picked an arbitrary log
-- (ROWNUM=1, no ORDER BY) which could return a SMALLER size when ORLs
-- have been grown over time, silently undersizing every SRL built from it.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CEIL(MAX(BYTES)/1024/1024) FROM V$LOG;
EXIT;

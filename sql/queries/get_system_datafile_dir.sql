-- Get the directory of the SYSTEM datafile (FILE#=1) - a stable,
-- deterministic choice for PRIMARY_DATA_PATH (on a CDB the first
-- directory in sorted order can be a GUID/seed directory).
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT SUBSTR(NAME, 1, INSTR(NAME, '/', -1)-1)
FROM V$DATAFILE
WHERE FILE# = 1;
EXIT;

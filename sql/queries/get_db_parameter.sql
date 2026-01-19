-- Get database parameter value by name
-- Usage: sqlplus @get_db_parameter.sql parameter_name
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V$PARAMETER WHERE NAME = '&1';
EXIT;

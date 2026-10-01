-- Get the password file the instance is actually using (V$PASSWORDFILE_INFO,
-- 18c and later). FILE_NAME is NULL when no password file is in use. On
-- older releases the view does not exist and the caller falls back to the
-- conventional orapw<SID>/orapw<DB_NAME> locations.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT FILE_NAME FROM V$PASSWORDFILE_INFO WHERE FILE_NAME IS NOT NULL AND ROWNUM = 1;
EXIT;

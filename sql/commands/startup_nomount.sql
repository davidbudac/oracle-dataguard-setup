-- Start instance in NOMOUNT mode with pfile
-- Usage: sqlplus @startup_nomount.sql pfile_path
SET HEADING OFF FEEDBACK ON VERIFY OFF
STARTUP NOMOUNT PFILE='&1';
EXIT;

-- Create SPFILE from PFILE
-- Usage: sqlplus @create_spfile.sql pfile_path
SET HEADING OFF FEEDBACK ON VERIFY OFF
CREATE SPFILE FROM PFILE='&1';
EXIT;

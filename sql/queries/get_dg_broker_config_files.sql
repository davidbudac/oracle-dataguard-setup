-- Get the primary's broker configuration file parameters (name|value|isdefault)
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT name || '|' || value || '|' || isdefault
FROM v$parameter
WHERE name IN ('dg_broker_config_file1', 'dg_broker_config_file2')
ORDER BY name;
EXIT;

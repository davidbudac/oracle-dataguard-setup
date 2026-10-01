-- Parameters that steer file placement and are inherited by a standby
-- created with RMAN DUPLICATE ... SPFILE (only the parameters named in
-- the SET clauses are overridden). One "name|value" row per parameter
-- that is set; unset (NULL) parameters return no row.
--   db_create_online_log_dest_1..5 - take precedence over
--       db_create_file_dest for online/standby redo logs and OMF
--       control files
--   log_file_name_convert / db_file_name_convert - rank above the OMF
--       parameters in RMAN's file-naming precedence
-- Used by step 1 (local) and step 5 (connected to the primary).
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT NAME || '|' || VALUE
FROM V$PARAMETER
WHERE NAME IN (
    'db_create_online_log_dest_1',
    'db_create_online_log_dest_2',
    'db_create_online_log_dest_3',
    'db_create_online_log_dest_4',
    'db_create_online_log_dest_5',
    'log_file_name_convert',
    'db_file_name_convert'
)
AND VALUE IS NOT NULL
ORDER BY NAME;
EXIT;

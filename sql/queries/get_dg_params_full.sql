-- Get all key Data Guard parameters (with headers for display)
SET LINESIZE 200 PAGESIZE 50
COLUMN NAME FORMAT A30
COLUMN VALUE FORMAT A100
SELECT NAME, VALUE
FROM V$PARAMETER
WHERE NAME IN (
    'db_name',
    'db_unique_name',
    'dg_broker_start',
    'log_archive_dest_1',
    'log_archive_dest_2',
    'standby_file_management'
)
ORDER BY NAME;
EXIT;

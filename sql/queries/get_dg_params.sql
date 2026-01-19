-- Get key Data Guard parameters (with headers for display)
SET LINESIZE 200 PAGESIZE 100
COLUMN NAME FORMAT A30
COLUMN VALUE FORMAT A100
SELECT NAME, VALUE
FROM V$PARAMETER
WHERE NAME IN (
    'dg_broker_start',
    'dg_broker_config_file1',
    'dg_broker_config_file2',
    'standby_file_management'
)
ORDER BY NAME;
EXIT;

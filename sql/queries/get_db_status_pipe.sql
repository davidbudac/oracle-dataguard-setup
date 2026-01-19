-- Get database status as pipe-delimited string (for parsing)
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS
FROM V$DATABASE;
EXIT;

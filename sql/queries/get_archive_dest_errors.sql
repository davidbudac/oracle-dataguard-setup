-- Get archive destination error details (with headers for display)
SET LINESIZE 200 PAGESIZE 50
SELECT DEST_ID, ERROR FROM V$ARCHIVE_DEST WHERE STATUS = 'ERROR';
EXIT;

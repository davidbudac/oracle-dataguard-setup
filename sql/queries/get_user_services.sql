-- Get user-defined services (excludes system services)
-- Returns one service name per line
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT NAME
FROM V$ACTIVE_SERVICES
WHERE NAME NOT IN (
    SELECT DB_UNIQUE_NAME FROM V$DATABASE
    UNION ALL
    SELECT NAME FROM V$DATABASE
    UNION ALL
    SELECT INSTANCE_NAME FROM V$INSTANCE
)
AND NAME NOT LIKE 'SYS$%'
AND UPPER(NAME) NOT LIKE '%XDB%'
-- Broker-internal services: <db>_CFG is created by the Data Guard broker and
-- <db>_DGMGRL is the static listener service. Neither is a user service - the
-- role trigger must not start/stop them and the handoff report must not
-- publish connect strings for them.
AND UPPER(NAME) NOT LIKE '%\_CFG' ESCAPE '\'
AND UPPER(NAME) NOT LIKE '%\_DGMGRL' ESCAPE '\'
ORDER BY NAME;
EXIT;

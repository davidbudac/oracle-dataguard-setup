-- Get user-defined services (excludes system services)
-- Returns one service name per line
--
-- Excludes (all compared case-insensitively):
--   - SYS$* system services
--   - The default services: DB_NAME, DB_UNIQUE_NAME and INSTANCE_NAME, each
--     also with the '.<db_domain>' suffix when db_domain is set. A default
--     service is registered wherever the database is up, so the role trigger
--     must never stop it on the standby.
--   - The XDB dispatcher services: <db_name>XDB, <db_unique_name>XDB and
--     <instance_name>XDB (and their domain-qualified forms) - exact names only,
--     so a user service that merely contains 'XDB' is still offered.
--   - Broker-internal <db>_CFG / <db>_DGMGRL services.
-- The default-service semantics mirror the DEFAULT classification in
-- dg_handoff.sh (QTAG:active_services); keep the two in step.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT s.NAME
FROM V$ACTIVE_SERVICES s
WHERE UPPER(s.NAME) NOT IN (
    SELECT UPPER(n) FROM (
        SELECT NAME AS n FROM V$DATABASE
        UNION ALL
        SELECT DB_UNIQUE_NAME FROM V$DATABASE
        UNION ALL
        SELECT INSTANCE_NAME FROM V$INSTANCE
        UNION ALL
        SELECT NAME || 'XDB' FROM V$DATABASE
        UNION ALL
        SELECT DB_UNIQUE_NAME || 'XDB' FROM V$DATABASE
        UNION ALL
        SELECT INSTANCE_NAME || 'XDB' FROM V$INSTANCE
        UNION ALL
        SELECT d.NAME || '.' || p.VALUE
          FROM V$DATABASE d, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
        UNION ALL
        SELECT d.DB_UNIQUE_NAME || '.' || p.VALUE
          FROM V$DATABASE d, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
        UNION ALL
        SELECT i.INSTANCE_NAME || '.' || p.VALUE
          FROM V$INSTANCE i, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
        UNION ALL
        SELECT d.NAME || 'XDB.' || p.VALUE
          FROM V$DATABASE d, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
        UNION ALL
        SELECT d.DB_UNIQUE_NAME || 'XDB.' || p.VALUE
          FROM V$DATABASE d, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
        UNION ALL
        SELECT i.INSTANCE_NAME || 'XDB.' || p.VALUE
          FROM V$INSTANCE i, V$PARAMETER p
         WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
    ) WHERE n IS NOT NULL
)
AND s.NAME NOT LIKE 'SYS$%'
-- Broker-internal services: <db>_CFG is created by the Data Guard broker and
-- <db>_DGMGRL is the static listener service. Neither is a user service - the
-- role trigger must not start/stop them and the handoff report must not
-- publish connect strings for them.
AND UPPER(s.NAME) NOT LIKE '%\_CFG' ESCAPE '\'
AND UPPER(s.NAME) NOT LIKE '%\_DGMGRL' ESCAPE '\'
ORDER BY s.NAME;
EXIT;

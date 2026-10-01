-- Get user-defined services across all containers (CDB-aware).
-- Returns one "CONTAINER|SERVICE" pair per line, where CONTAINER is the
-- PDB name (or CDB$ROOT for root-level services).
--
-- Excludes (all compared case-insensitively):
--   - System services (SYS$*)
--   - PDB$SEED
--   - The default per-container service (service name = container name, with
--     or without the '.<db_domain>' suffix)
--   - The CDB-level DB_NAME / DB_UNIQUE_NAME / INSTANCE_NAME services, with
--     or without the '.<db_domain>' suffix
--   - The XDB dispatcher services: <db_name>XDB, <db_unique_name>XDB and
--     <instance_name>XDB (and their domain-qualified forms) - exact names only,
--     so a user service that merely contains 'XDB' is still offered.
--   - Broker-internal <db>_CFG / <db>_DGMGRL services.
-- The default-service semantics mirror the DEFAULT classification in
-- dg_handoff.sh (QTAG:active_services); keep the two in step.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT c.NAME || '|' || s.NAME
FROM V$ACTIVE_SERVICES s
JOIN V$CONTAINERS c ON c.CON_ID = s.CON_ID
WHERE s.NAME NOT LIKE 'SYS$%'
  -- Broker-internal services: <db>_CFG is created by the Data Guard broker
  -- and <db>_DGMGRL is the static listener service. Neither is a user
  -- service - the role trigger must not start/stop them.
  AND UPPER(s.NAME) NOT LIKE '%\_CFG' ESCAPE '\'
  AND UPPER(s.NAME) NOT LIKE '%\_DGMGRL' ESCAPE '\'
  AND c.NAME <> 'PDB$SEED'
  AND UPPER(s.NAME) <> UPPER(c.NAME)
  AND UPPER(s.NAME) NOT IN (
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
  -- Container default service with the domain suffix: <container>.<db_domain>
  AND NOT EXISTS (
    SELECT 1 FROM V$PARAMETER p
     WHERE p.NAME = 'db_domain' AND p.VALUE IS NOT NULL
       AND UPPER(s.NAME) = UPPER(c.NAME) || '.' || UPPER(p.VALUE)
  )
ORDER BY c.NAME, s.NAME;
EXIT;

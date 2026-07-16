-- Get user-defined services across all containers (CDB-aware).
-- Returns one "CONTAINER|SERVICE" pair per line, where CONTAINER is the
-- PDB name (or CDB$ROOT for root-level services).
--
-- Excludes:
--   - System services (SYS$%, XDB)
--   - PDB$SEED
--   - The default per-container service (service name = container name)
--   - The CDB-level DB/DB_UNIQUE_NAME/instance services
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT c.NAME || '|' || s.NAME
FROM V$ACTIVE_SERVICES s
JOIN V$CONTAINERS c ON c.CON_ID = s.CON_ID
WHERE s.NAME NOT LIKE 'SYS$%'
  AND UPPER(s.NAME) NOT LIKE '%XDB%'
  AND c.NAME <> 'PDB$SEED'
  AND UPPER(s.NAME) <> UPPER(c.NAME)
  AND s.NAME NOT IN (
        SELECT DB_UNIQUE_NAME FROM V$DATABASE
        UNION ALL
        SELECT NAME FROM V$DATABASE
        UNION ALL
        SELECT INSTANCE_NAME FROM V$INSTANCE
  )
ORDER BY c.NAME, s.NAME;
EXIT;

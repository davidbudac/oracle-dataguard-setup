-- HA-relevant attributes for every user-visible service: TAF settings,
-- Transaction Guard (COMMIT_OUTCOME), drain and session-restore behavior.
-- The handoff report states these as discovered facts per service instead
-- of "where the DBA configured it" hedging.
-- CDB_SERVICES so PDB services resolve when run from CDB$ROOT; on a non-CDB
-- it is equivalent to DBA_SERVICES.
-- Returns: NAME|FAILOVER_TYPE|FAILOVER_METHOD|FAILOVER_RETRIES|FAILOVER_DELAY|COMMIT_OUTCOME|DRAIN_TIMEOUT|FAILOVER_RESTORE
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT NAME || '|' ||
       NVL(FAILOVER_TYPE, 'NONE') || '|' ||
       NVL(FAILOVER_METHOD, '-') || '|' ||
       NVL(TO_CHAR(FAILOVER_RETRIES), '-') || '|' ||
       NVL(TO_CHAR(FAILOVER_DELAY), '-') || '|' ||
       NVL(COMMIT_OUTCOME, 'false') || '|' ||
       NVL(TO_CHAR(DRAIN_TIMEOUT), '-') || '|' ||
       NVL(FAILOVER_RESTORE, 'NONE')
FROM CDB_SERVICES
WHERE NAME NOT LIKE 'SYS$%';
EXIT;

-- ============================================================
-- Check Data Guard role-aware service trigger deployment
-- Returns: package_count|enabled_trigger_count|trigger_count|owners
-- ============================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
WITH pkg AS (
    SELECT owner
    FROM DBA_OBJECTS
    WHERE OBJECT_NAME = 'DG_SERVICE_MGR'
      AND OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY')
      AND STATUS = 'VALID'
),
trg AS (
    SELECT owner, trigger_name, status
    FROM DBA_TRIGGERS
    WHERE trigger_name IN ('TRG_MANAGE_SERVICES_ROLE_CHG', 'TRG_MANAGE_SERVICES_STARTUP')
)
SELECT
    (SELECT COUNT(DISTINCT owner) FROM pkg) || '|' ||
    (SELECT COUNT(*) FROM trg WHERE status = 'ENABLED') || '|' ||
    (SELECT COUNT(*) FROM trg) || '|' ||
    NVL((SELECT LISTAGG(owner, ',') WITHIN GROUP (ORDER BY owner)
         FROM (SELECT DISTINCT owner FROM pkg
               UNION
               SELECT DISTINCT owner FROM trg)), 'NONE')
FROM DUAL;
EXIT;

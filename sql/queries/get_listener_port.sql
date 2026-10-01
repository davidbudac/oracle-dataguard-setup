-- Get the local listener address(es) from V$LISTENER_NETWORK. VALUE is the
-- whole address, e.g. (ADDRESS=(PROTOCOL=TCP)(HOST=h)(PORT=1521)); the caller
-- extracts and validates the numeric PORT. ORDER BY keeps "first" stable
-- when several local listeners are registered.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' ORDER BY VALUE;
EXIT;

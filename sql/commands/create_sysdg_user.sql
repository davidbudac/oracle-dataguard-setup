-- Create user with SYSDG privilege for Data Guard observer
-- Usage: sqlplus @create_sysdg_user.sql username password
SET HEADING OFF FEEDBACK OFF VERIFY OFF
CREATE USER &1 IDENTIFIED BY "&2";
GRANT SYSDG TO &1;
GRANT CREATE SESSION TO &1;
SELECT 'SUCCESS' FROM DUAL;
EXIT;

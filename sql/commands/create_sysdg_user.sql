-- Create SYSDG user for Data Guard observer
-- Usage: sqlplus @create_sysdg_user.sql password
SET HEADING OFF FEEDBACK OFF VERIFY OFF
CREATE USER sysdg IDENTIFIED BY "&1";
GRANT SYSDG TO sysdg;
GRANT CREATE SESSION TO sysdg;
SELECT 'SUCCESS' FROM DUAL;
EXIT;

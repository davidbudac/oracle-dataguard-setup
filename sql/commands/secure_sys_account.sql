-- Change SYS password and lock account
-- Usage: sqlplus @secure_sys_account.sql new_password
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS IDENTIFIED BY "&1";
ALTER USER SYS ACCOUNT LOCK;
SELECT 'SUCCESS' FROM DUAL;
EXIT;

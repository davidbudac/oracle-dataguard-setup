-- Change SYS password and lock account
-- Usage: sqlplus @secure_sys_account.sql new_password
-- WHENEVER SQLERROR EXIT ensures a failed password change (e.g. rejected
-- by a password verify function) aborts BEFORE the ACCOUNT LOCK statement
-- runs, so we never lock SYS while leaving the old password in place.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS IDENTIFIED BY "&1";
ALTER USER SYS ACCOUNT LOCK;
EXIT SUCCESS;

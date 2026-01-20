-- Add standby redo log file
-- Usage: sqlplus @add_standby_logfile.sql group_number file_path size_mb
SET HEADING OFF FEEDBACK ON VERIFY OFF
ALTER DATABASE ADD STANDBY LOGFILE GROUP &1 ('&2') SIZE &3.M;
EXIT;

-- Add standby redo log file, explicitly assigned to a redo thread.
-- Usage: sqlplus @add_standby_logfile.sql thread_number group_number file_path size_mb
-- The THREAD clause matters: an SRL created without one sits at THREAD#=0
-- until RFS first uses it, and DGMGRL VALIDATE DATABASE reports such SRLs
-- as "not configured for thread N" - which blocks the step 13 MAXAVAILABILITY
-- preflight and confuses per-thread SRL accounting.
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK ON VERIFY OFF
ALTER DATABASE ADD STANDBY LOGFILE THREAD &1 GROUP &2 ('&3') SIZE &4.M;
EXIT;

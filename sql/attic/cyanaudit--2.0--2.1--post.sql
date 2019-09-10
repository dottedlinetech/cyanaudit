SET client_min_messages TO warning;

DROP FUNCTION IF EXISTS cyanaudit.fn_setup_partition_inheritance( varchar );
DROP FUNCTION IF EXISTS cyanaudit.fn_setup_partition_constraints( varchar );
DROP FUNCTION IF EXISTS cyanaudit.fn_verify_partition_config();

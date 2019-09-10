SET client_min_messages TO warning;

DROP FUNCTION IF EXISTS cyanaudit.fn_prune_archive( integer, interval, integer );

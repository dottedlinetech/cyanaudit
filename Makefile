EXTENSION = auditlog
DATA = auditlog--*0.3.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

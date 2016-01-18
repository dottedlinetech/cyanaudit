#!/bin/bash

# This script moves all of your archive tables to your archive_tablespace if
# they're not already there. It will do one transaction per table so as to avoid
# unnecessary locking. This generates a lot of WAL files, so you may want to put
# a sleep in the while loop to let your slave catch up between moves.

# Remember to export your PGHOST, PGUSER, PGDATABASE and PGPORT.

# TODO: Update to use fn_archive_partition() and perl's
# get_cyanaudit_archive_table_list or similar for initial query

psql -t -A -c "
   select 'alter '
       || case when c.relkind = 'r'
               then 'table '
               when c.relkind = 'i'
               then 'index '
          end
       || n.nspname||'.'||c.relname
       || ' set tablespace '
       || quote_ident(current_setting('cyanaudit.archive_tablespace'))
       || ';'
     from pg_class c
     join pg_namespace n
       on c.relnamespace = n.oid
     join pg_extension e
       on e.extnamespace = n.oid
      and e.extname = 'cyanaudit'
left join pg_tablespace t
       on c.reltablespace = t.oid
    where t.spcname is distinct from current_setting('cyanaudit.archive_tablespace')
      and c.relname ~ '^tb_audit_event_\d{8}_\d{4}$'
      and c.relkind in ('r','i')
    order by c.relname" | 
while read command; do
    echo "$command"
    psql -c "$command" || break
    # sleep 30
done

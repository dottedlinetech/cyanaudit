------------------------
------ FUNCTIONS ------
------------------------

do language plpgsql
 $$
declare
    my_value            varchar;
    my_version          integer[];
    my_command          varchar;
begin
    my_version := regexp_matches(version(), 'PostgreSQL (\d)+\.(\d+)\.(\d+)');

    -- Verify minimum version
    if my_version < array[9,3,3]::integer[] then
        raise exception 'Cyan Audit requires PostgreSQL 9.3.3 or above';
    end if;

    -- Install pl/perl if necessary
    if (select count(*) from pg_language where lanname = 'plperl') = 0 then
        begin
            create language plperl;
            alter extension cyanaudit drop language plperl;
            alter extension cyanaudit drop function plperl_call_handler();
            alter extension cyanaudit drop function plperl_inline_handler(internal);
            alter extension cyanaudit drop function plperl_validator(oid);
        exception
            when undefined_object then
                 raise exception 'Cyan Audit requires lanugage plperl.';
        end;
    end if;

    -- Make sure we are installing to a non-public schema
    if '@extschema@' = 'public' then
        raise exception 'Must install to schema other than public, e.g. cyanaudit';
    end if;

    -- Set default values for configuration parameters
    my_command := 'alter database ' || quote_ident(current_database()) || ' ';
    execute my_command || 'set cyanaudit.enabled = 1';
    execute my_command || 'set cyanaudit.uid = -1';
    execute my_command || 'set cyanaudit.last_txid = 0';
    execute my_command || 'set cyanaudit.archive_tablespace = pg_default';
    execute my_command || 'set cyanaudit.user_table = '''' ';
    execute my_command || 'set cyanaudit.user_table_uid_col = '''' ';
    execute my_command || 'set cyanaudit.user_table_email_col = '''' ';
    execute my_command || 'set cyanaudit.user_table_username_col = '''' ';
end;
 $$;

-- fn_set_audit_uid
CREATE OR REPLACE FUNCTION @extschema@.fn_set_audit_uid
(
    in_uid   integer
)
returns integer as
 $_$
begin
    return set_config('cyanaudit.uid', in_uid::varchar, false);
end;
 $_$
    language plpgsql strict;


-- fn_get_audit_uid
CREATE OR REPLACE FUNCTION @extschema@.fn_get_audit_uid() returns integer as
 $_$
declare
    my_uid    integer;
begin
    my_uid := coalesce( nullif( current_setting('cyanaudit.uid'), '' )::integer, -1 );

    if my_uid >= 0 then return my_uid; end if;

    select @extschema@.fn_get_audit_uid_by_username(current_user::varchar)
      into my_uid;

    return @extschema@.fn_set_audit_uid( coalesce( my_uid, 0 ) );
exception
    when undefined_object
    then return @extschema@.fn_set_audit_uid( 0 );
end
 $_$
    language plpgsql stable;


-- fn_set_last_audit_txid
CREATE OR REPLACE FUNCTION @extschema@.fn_set_last_audit_txid
(
    bigint default txid_current()
)
returns bigint as
 $_$
    SELECT (set_config('cyanaudit.last_txid', $1::varchar, false))::bigint;
 $_$
    language sql strict;


-- fn_get_last_audit_txid
CREATE OR REPLACE FUNCTION @extschema@.fn_get_last_audit_txid()
returns bigint as
 $_$
    SELECT (nullif(current_setting('cyanaudit.last_txid'), '0'))::bigint;
 $_$
    language sql stable;


-- fn_get_email_by_audit_uid
CREATE OR REPLACE FUNCTION @extschema@.fn_get_email_by_audit_uid
(
    in_uid  integer
)
returns varchar as
 $_$
declare
    my_email                varchar;
    my_query                varchar;
    my_user_table_uid_col   varchar;
    my_user_table           varchar;
    my_user_table_email_col varchar;
begin
    select current_setting('cyanaudit.user_table'),
           current_setting('cyanaudit.user_table_uid_col'),
           current_setting('cyanaudit.user_table_email_col')
      into my_user_table,
           my_user_table_uid_col,
           my_user_table_email_col;

    if my_user_table            = '' OR
       my_user_table_uid_col    = '' OR
       my_user_table_email_col  = ''
    then
        return null;
    end if;

    my_query := 'select ' || my_user_table_email_col
             || '  from ' || my_user_table
             || ' where ' || my_user_table_uid_col
                          || ' = ' || in_uid;
    execute my_query
       into my_email;

    return my_email;
exception
    when undefined_object then 
         return null;
    when undefined_table then 
         raise notice 'Cyan Audit: Invalid user_table';
         return null;
    when undefined_column then 
         raise notice 'Cyan Audit: Invalid user_table_uid_col or user_table_email_col';
         return null;
end
 $_$
    language plpgsql stable strict;


-- fn_get_audit_uid_by_username
CREATE OR REPLACE FUNCTION @extschema@.fn_get_audit_uid_by_username
(
    in_username varchar
)
returns integer as
 $_$
declare
    my_uid                      varchar;
    my_query                    varchar;
    my_user_table_uid_col       varchar;
    my_user_table               varchar;
    my_user_table_username_col  varchar;
begin
    select current_setting('cyanaudit.user_table'),
           current_setting('cyanaudit.user_table_uid_col'),
           current_setting('cyanaudit.user_table_username_col')
      into my_user_table,
           my_user_table_uid_col,
           my_user_table_username_col;

    if my_user_table                = '' OR
       my_user_table_uid_col        = '' OR
       my_user_table_username_col   = ''
    then
        return null;
    end if;

    my_query := 'select ' || my_user_table_uid_col
             || '  from ' || my_user_table
             || ' where ' || my_user_table_username_col
                          || ' = ''' || in_username || '''';
    execute my_query
       into my_uid;

    return my_uid;
exception
    when undefined_object then 
         return null;
    when undefined_table then 
         raise notice 'Cyan Audit: Invalid user_table';
         return null;
    when undefined_column then 
         raise notice 'Cyan Audit: Invalid user_table_uid_col or user_table_username_col';
         return null;
end
 $_$
    language plpgsql stable strict;


-- fn_get_table_pk_col
CREATE OR REPLACE FUNCTION @extschema@.fn_get_table_pk_col
(
    in_table_name   varchar,
    in_table_schema varchar default 'public'
)
returns varchar as
 $_$
declare
    my_pk_col   varchar;
begin
    select a.attname
      into strict my_pk_col
      from pg_attribute a
      join pg_class c
        on a.attrelid = c.oid
      join pg_namespace n
        on c.relnamespace = n.oid
      join pg_constraint cn
        on a.attrelid = cn.conrelid
       and a.attnum = any(cn.conkey)
       and cn.contype = 'p'
       and array_length(cn.conkey, 1) = 1
       and c.relname::varchar = in_table_name
       and n.nspname::varchar = in_table_schema;

    return my_pk_col;
exception
    when too_many_rows or no_data_found then 
        return null;
end
 $_$
    language 'plpgsql' stable strict;



-- fn_get_or_create_audit_transaction_type
CREATE OR REPLACE FUNCTION @extschema@.fn_get_or_create_audit_transaction_type
(
    in_label    varchar
)
returns integer as
 $_$
declare
    my_audit_transaction_type   integer;
begin
    select audit_transaction_type
      into my_audit_transaction_type
      from @extschema@.tb_audit_transaction_type
     where label = in_label;

    if not found then
        my_audit_transaction_type := nextval('@extschema@.sq_pk_audit_transaction_type');

        insert into @extschema@.tb_audit_transaction_type
                    (
                        audit_transaction_type,
                        label
                    )
                    values
                    (
                        my_audit_transaction_type,
                        in_label
                    );
    end if;

    return my_audit_transaction_type;
end
 $_$
    language 'plpgsql' strict;

        
-- fn_label_audit_transaction
CREATE OR REPLACE FUNCTION @extschema@.fn_label_audit_transaction
(
    in_label    varchar,
    in_txid     bigint default txid_current()
)
returns bigint as
 $_$
declare
    my_audit_transaction_type   integer;
begin
    select @extschema@.fn_get_or_create_audit_transaction_type(in_label)
      into my_audit_transaction_type;

    update @extschema@.tb_audit_event_current
       set audit_transaction_type = my_audit_transaction_type
     where txid = in_txid
       and audit_transaction_type is null;

    return in_txid;
end
 $_$
    language 'plpgsql' strict;



-- fn_label_last_audit_transaction
CREATE OR REPLACE FUNCTION @extschema@.fn_label_last_audit_transaction
(
    in_label    varchar
)
returns bigint as
 $_$
begin
    return @extschema@.fn_label_audit_transaction
           (
                in_label, 
                @extschema@.fn_get_last_audit_txid()
           );
end
 $_$
    language 'plpgsql' strict;

-- fn_undo_transaction
CREATE OR REPLACE FUNCTION @extschema@.fn_undo_transaction
(
    in_txid   bigint
)
returns setof varchar as
 $_$
declare
    my_statement    varchar;
begin
    for my_statement in
        select query 
          from vw_audit_transaction_statement_inverse
         where txid = in_txid
    loop
        execute my_statement;
        return next my_statement;
    end loop;

    perform @extschema@.fn_label_audit_transaction('Undo transaction');

    return;
end
 $_$
    language 'plpgsql' strict;


-- fn_undo_last_transaction
CREATE OR REPLACE FUNCTION @extschema@.fn_undo_last_transaction()
returns setof varchar as
 $_$
    select @extschema@.fn_undo_transaction(@extschema@.fn_get_last_audit_txid());
 $_$
    language 'sql';



-- fn_get_or_create_audit_field
CREATE OR REPLACE FUNCTION @extschema@.fn_get_or_create_audit_field
(
    in_table_name       varchar,
    in_column_name      varchar,
    in_table_schema     varchar default 'public'
)
returns integer as
 $_$
declare
    my_audit_field   integer;
begin
    select audit_field
      into my_audit_field
      from @extschema@.tb_audit_field
     where table_schema = in_table_schema
       and table_name = in_table_name
       and column_name = in_column_name;

    if not found then
        insert into @extschema@.tb_audit_field
        (
            table_schema,
            table_name,
            column_name
        )
        values
        (
            in_table_schema,
            in_table_name, 
            in_column_name
        )
        returning audit_field
        into my_audit_field;
    end if;

    return my_audit_field;
end
 $_$
    language 'plpgsql';
        


-- fn_new_audit_event
CREATE OR REPLACE FUNCTION @extschema@.fn_new_audit_event
(
    in_audit_field      integer, -- FK into tb_audit_field
    in_row_pk_val       integer, -- value of primary key of this row
    in_recorded         timestamp, -- clock timestamp of row op
    in_row_op           varchar, -- 'INSERT', 'UPDATE', or 'DELETE'
    in_old_value        anyelement, -- old value or null if INSERT
    in_new_value        anyelement  -- new value or null if DELETE
)
returns void as
 $_$
begin
    if (in_row_op = 'UPDATE' and 
        in_old_value::text is not distinct from in_new_value::text) OR
       (in_row_op = 'INSERT' and 
        in_new_value is null)
    then
        return;
    end if;

    insert into @extschema@.tb_audit_event
    (
        audit_field,
        row_pk_val,
        recorded,
        row_op,
        old_value,
        new_value
    )
    values
    (
        in_audit_field,
        in_row_pk_val,
        in_recorded,
        in_row_op::char(1),
        case when in_row_op = 'INSERT' then null else in_old_value end,
        case when in_row_op = 'DELETE' then null else in_new_value end
    );
end
 $_$
    language 'plpgsql';


-- fn_drop_audit_event_log_trigger
CREATE OR REPLACE FUNCTION @extschema@.fn_drop_audit_event_log_trigger 
(
    in_table_name   varchar,
    in_table_schema varchar default 'public'
)
returns void as
 $_$
declare
    my_function_name    varchar;
begin
    my_function_name := 'fn_log_audit_event_' || (in_table_schema||'.'||in_table_name)::regclass::oid::text;

    set client_min_messages to warning;

    perform p.proname
       from pg_catalog.pg_depend d
       join pg_catalog.pg_proc p
         on d.classid = 'pg_proc'::regclass::oid
        and d.objid = p.oid
       join pg_catalog.pg_extension e
         on d.refclassid = 'pg_extension'::regclass::oid
        and d.refobjid = e.oid
      where e.extname = 'cyanaudit'
        and p.proname = my_function_name;

    if found then
        execute 'alter extension cyanaudit drop function '
             || '@extschema@.' || my_function_name|| '()';
    end if;

    perform p.proname
       from pg_proc p
       join pg_namespace n
         on p.pronamespace = n.oid
        and n.nspname = '@extschema@'
      where p.proname = my_function_name;

    if found then
        execute 'drop function '
             || '@extschema@.'||my_function_name||'() cascade';
    end if;

    set client_min_messages to notice;
end
 $_$
    language 'plpgsql';



-- fn_update_audit_event_log_trigger_on_table
CREATE OR REPLACE FUNCTION @extschema@.fn_update_audit_event_log_trigger_on_table
(
    in_table_name   varchar,
    in_table_schema varchar default 'public'
)
returns void as
 $_$
use strict;

my $table_name = $_[0];
my $table_schema = $_[1];
my $table_oid_rv = spi_exec_query( "select '$table_schema.$table_name'::regclass::oid" );
my $table_oid = $table_oid_rv->{rows}[0]->{oid};

return if $table_name =~ /tb_audit_.*/;

my $table_q = "select relname "
            . "  from pg_class c "
            . "  join pg_namespace n "
            . "    on c.relnamespace = n.oid "
            . " where n.nspname = '$table_schema' "
            . "   and c.relname = '$table_name' ";

my $table_rv = spi_exec_query($table_q);

if( $table_rv->{'processed'} == 0 )
{
    elog(NOTICE, "Cannot audit invalid table '$table_schema.$table_name'");
    return;
}

my $colnames_q = "select audit_field, column_name "
               . "  from @extschema@.tb_audit_field "
               . " where table_name = '$table_name' "
               . "   and table_schema = '$table_schema' "
               . "   and active = true ";

my $colnames_rv = spi_exec_query($colnames_q);

if( $colnames_rv->{'processed'} == 0 )
{
    my $q = "select @extschema@.fn_drop_audit_event_log_trigger('$table_name', '$table_schema')";
    eval{ spi_exec_query($q) };
    elog(ERROR, "fn_drop_audit_event_log_trigger: $@") if($@);
    return;
}

my $pk_q = "select @extschema@.fn_get_table_pk_col('$table_name', '$table_schema') as pk_col ";

my $pk_rv = spi_exec_query($pk_q);

my $pk_col = $pk_rv->{'rows'}[0]{'pk_col'};

unless( $pk_col )
{
    my $pk2_q = "select column_name as pk_col "
              . "  from @extschema@.tb_audit_field "
              . " where table_pk = audit_field "
              . "   and table_name = '$table_name' "
              . "   and table_schema = '$table_schema' ";

    my $pk2_rv = spi_exec_query($pk2_q);

    $pk_col = $pk2_rv->{'rows'}[0]{'pk_col'};

    unless( $pk_col )
    {
        elog(NOTICE, "pk_col is null");
        return;
    }
}

my $fn_q = <<EOF;
CREATE OR REPLACE FUNCTION @extschema@.fn_log_audit_event_${table_oid}()
returns trigger as
 \$_\$
-- THIS FUNCTION AUTOMATICALLY GENERATED. DO NOT EDIT
DECLARE
    my_row_pk_val       integer;
    my_old_row          record;
    my_new_row          record;
    my_recorded         timestamp;
BEGIN
    if( TG_OP = 'INSERT' ) then
        my_row_pk_val := NEW.$pk_col;
    else
        my_row_pk_val := OLD.$pk_col;
    end if;

    if( TG_OP = 'DELETE' ) then
        my_new_row := OLD;
    else
        my_new_row := NEW;
    end if;
    if( TG_OP = 'INSERT' ) then
        my_old_row := NEW;
    else
        my_old_row := OLD;
    end if;

    if current_setting('cyanaudit.enabled') = '0' then
        return my_new_row;
    end if;

    perform @extschema@.fn_set_last_audit_txid();

    my_recorded := clock_timestamp();

EOF

foreach my $row (@{$colnames_rv->{'rows'}})
{
    my $column_name = $row->{'column_name'};
    my $audit_field = $row->{'audit_field'};

    $fn_q .= <<EOF;
    IF (TG_OP = 'INSERT' AND
        my_new_row.${column_name} IS NOT NULL) OR
       (TG_OP = 'UPDATE' AND
        my_new_row.${column_name}::text IS DISTINCT FROM
        my_old_row.${column_name}::text) OR
       (TG_OP = 'DELETE' AND
        my_old_row.${column_name} IS NOT NULL)
    THEN
        perform @extschema@.fn_new_audit_event(
                    $audit_field,
                    my_row_pk_val,
                    my_recorded,
                    TG_OP,
                    my_old_row.$column_name,
                    my_new_row.$column_name
                );
    END IF;

EOF
}

$fn_q .= <<EOF;
    return NEW;
EXCEPTION
    WHEN undefined_function THEN
         raise notice 'Undefined function call. Please reinstall cyanaudit.';
         return NEW;
    WHEN undefined_column THEN
         raise notice 'Undefined column. Please run fn_update_audit_fields() as superuser.';
         return NEW;
    WHEN undefined_object THEN
         raise notice 'Cyan Audit configuration invalid. Logging disabled.';
         return NEW;
END
 \$_\$
    language 'plpgsql';
EOF

spi_exec_query( 'SET client_min_messages to WARNING' );

eval { spi_exec_query($fn_q) };
elog(ERROR, $@) if $@;

my $tg_q = "CREATE TRIGGER tr_log_audit_event_${table_oid} "
         . "   after insert or update or delete on $table_schema.$table_name for each row "
         . "   execute procedure @extschema@.fn_log_audit_event_${table_oid}()";
eval { spi_exec_query($tg_q) };

my $ext_q = "ALTER EXTENSION cyanaudit ADD FUNCTION @extschema@.fn_log_audit_event_${table_oid}()";

eval { spi_exec_query($ext_q) };

spi_exec_query( 'SET client_min_messages to NOTICE' );
 $_$
    language 'plperl';



-- fn_update_audit_fields
CREATE OR REPLACE FUNCTION @extschema@.fn_update_audit_fields
(
    in_schema varchar default 'public'
) 
returns void as
 $_$
begin
    perform *
       from @extschema@.tb_audit_field
      where audit_field = 0
        for update;

    if not found then
        insert into @extschema@.tb_audit_field 
             values (0, '[unknown]','[unknown]', '[unknown]', 0, false);
    end if;

    with tt_audit_fields as
    (
        select coalesce(
                   af.audit_field,
                   @extschema@.fn_get_or_create_audit_field(
                       c.relname::varchar,
                       a.attname::varchar,
                       n.nspname::varchar
                   )
               ) as audit_field,
               (a.attrelid is null and af.active) as stale
          from pg_attribute a
          join pg_class c
            on a.attrelid = c.oid
          join pg_namespace n
            on c.relnamespace = n.oid
           and n.nspname::varchar = in_schema
          join pg_constraint cn
            on cn.conrelid = c.oid
           and cn.contype = 'p'
           and array_length(cn.conkey, 1) = 1
           and a.attnum > 0
           and a.attisdropped is false
     full join @extschema@.tb_audit_field af
            on c.relname::varchar = af.table_name
           and a.attname::varchar = af.column_name
           and n.nspname::varchar = af.table_schema
         where af.table_schema = in_schema
            or af.table_schema is null
    )
    update @extschema@.tb_audit_field af
       set active = false
      from tt_audit_fields afs
     where afs.stale
       and afs.audit_field = af.audit_field;
end
 $_$
    language 'plpgsql';


--------- Audit event archiving -----------

create or replace function @extschema@.fn_redirect_audit_events() 
returns trigger as
 $_$
begin
    insert into @extschema@.tb_audit_event_current select NEW.*;
    return null;
end
 $_$
    language 'plpgsql';



------------------
----- TABLES -----
------------------

-- tb_audit_field
create sequence @extschema@.sq_pk_audit_field;

CREATE TABLE IF NOT EXISTS @extschema@.tb_audit_field
(
    audit_field     integer primary key default nextval('@extschema@.sq_pk_audit_field'),
    table_schema    varchar not null default 'public',
    table_name      varchar not null,
    column_name     varchar not null,
    table_pk        integer not null references @extschema@.tb_audit_field,
    active          boolean not null default true,
    CONSTRAINT tb_audit_field_table_column_key 
        UNIQUE( table_schema, table_name, column_name ),
    CONSTRAINT tb_audit_field_tb_audit_event_not_allowed 
        CHECK( table_name not like 'tb_audit_event%' )
);

alter sequence @extschema@.sq_pk_audit_field
    owned by @extschema@.tb_audit_field.audit_field;

SELECT pg_catalog.pg_extension_config_dump('@extschema@.tb_audit_field','');
SELECT pg_catalog.pg_extension_config_dump('@extschema@.sq_pk_audit_field','');



-- tb_audit_transaction_type
CREATE SEQUENCE @extschema@.sq_pk_audit_transaction_type;

CREATE TABLE IF NOT EXISTS @extschema@.tb_audit_transaction_type
(
    audit_transaction_type  integer primary key
                            default nextval('@extschema@.sq_pk_audit_transaction_type'),
    label                   varchar unique
);

ALTER SEQUENCE sq_pk_audit_transaction_type
    owned by @extschema@.tb_audit_transaction_type.audit_transaction_type;

CREATE SEQUENCE @extschema@.sq_pk_audit_event MAXVALUE 2147483647 CYCLE;

-- tb_audit_event
CREATE TABLE IF NOT EXISTS @extschema@.tb_audit_event
(
    audit_event             integer primary key 
                            default nextval('@extschema@.sq_pk_audit_event'),
    audit_field             integer not null 
                            references @extschema@.tb_audit_field,
    row_pk_val              integer not null,
    recorded                timestamp not null,
    uid                     integer not null default @extschema@.fn_get_audit_uid(),
    row_op                  char(1) not null CHECK (row_op in ('I','U','D')),
    txid                    bigint not null default txid_current(),
    audit_transaction_type  integer references @extschema@.tb_audit_transaction_type,
    old_value               text,
    new_value               text
);

ALTER TABLE tb_audit_event
    ADD CONSTRAINT tb_audit_event_null_on_insert_or_delete_chk
        CHECK( case when row_op = 'I' then old_value is null when row_op = 'D' then new_value is null end ),
    ADD CONSTRAINT tb_audit_event_changed_on_update_chk
        CHECK( case when row_op = 'U' then old_value is distinct from new_value end );

ALTER SEQUENCE @extschema@.sq_pk_audit_event
    owned by @extschema@.tb_audit_event.audit_event;

-- tb_audit_event_current
CREATE TABLE IF NOT EXISTS @extschema@.tb_audit_event_current() 
    inherits ( @extschema@.tb_audit_event );

drop index if exists @extschema@.tb_audit_event_current_txid_idx;
drop index if exists @extschema@.tb_audit_event_current_recorded_idx;
drop index if exists @extschema@.tb_audit_event_current_audit_field_idx;

create index tb_audit_event_current_txid_idx
    on @extschema@.tb_audit_event_current(txid);
create index tb_audit_event_current_recorded_idx
    on @extschema@.tb_audit_event_current(recorded);
create index tb_audit_event_current_audit_field_idx
    on @extschema@.tb_audit_event_current(audit_field);

drop trigger if exists tr_redirect_audit_events on @extschema@.tb_audit_event;
create trigger tr_redirect_audit_events 
    before insert on @extschema@.tb_audit_event
    for each row execute procedure @extschema@.fn_redirect_audit_events();



--------------------
------ VIEWS -------
--------------------

-- log view
CREATE OR REPLACE VIEW @extschema@.vw_audit_log as
   select ae.recorded, 
          ae.uid, 
          @extschema@.fn_get_email_by_audit_uid(ae.uid) as user_email,
          ae.txid, 
          att.label as description,
          case when af.table_schema = any(current_schemas(true))
               then af.table_name
               else af.table_schema || '.' || af.table_name
          end as table_name,
          af.column_name,
          ae.row_pk_val as pk_val,
          ae.row_op as op,
          ae.old_value,
          ae.new_value
     from @extschema@.tb_audit_event ae
     join @extschema@.tb_audit_field af using(audit_field)
left join @extschema@.tb_audit_transaction_type att using(audit_transaction_type)
 order by ae.recorded desc, af.table_name, af.column_name;


-- vw_audit_transaction_statement
CREATE OR REPLACE VIEW @extschema@.vw_audit_transaction_statement as
   select ae.txid, 
          ae.recorded,
          @extschema@.fn_get_email_by_audit_uid(ae.uid) as user_email,
          att.label as description, 
          (case 
          when ae.row_op = 'I' then
               'INSERT INTO ' || af.table_schema || '.' || af.table_name || ' ('
               || array_to_string(array_agg('"'||af.column_name||'"'), ',') 
               || ') VALUES ('
               || array_to_string(array_agg(coalesce(
                    quote_literal(ae.new_value), 'NULL'
                  )), ',') ||');'
          when ae.row_op = 'U' then
               'UPDATE ' || af.table_schema || '.' || af.table_name || ' SET '
               || array_to_string(array_agg(af.column_name||' = '||coalesce(
                    quote_literal(ae.new_value), 'NULL'
                  )), ', ') || ' WHERE ' || afpk.column_name || ' = ' 
               || quote_literal(ae.row_pk_val) || ';'
          when ae.row_op = 'D' then
               'DELETE FROM ' || af.table_schema || '.' || af.table_name || ' WHERE ' || afpk.column_name
               ||' = '||quote_literal(ae.row_pk_val) || ';'
          end)::varchar as query
     from @extschema@.tb_audit_event ae
     join @extschema@.tb_audit_field af using(audit_field)
     join @extschema@.tb_audit_field afpk on af.table_pk = afpk.audit_field
left join @extschema@.tb_audit_transaction_type att using(audit_transaction_type)
 group by af.table_schema, af.table_name, ae.row_op, afpk.column_name,
          ae.row_pk_val, ae.txid, ae.recorded,
          att.label, @extschema@.fn_get_email_by_audit_uid(ae.uid)
 order by ae.recorded;


-- vw_audit_transaction_statement_inverse
CREATE OR REPLACE VIEW @extschema@.vw_audit_transaction_statement_inverse AS
   select ae.txid,
          (case ae.row_op
           when 'D' then 
                'INSERT INTO ' || af.table_schema || '.' || af.table_name || ' ('
                || array_to_string(
                     array_agg('"'||af.column_name||'"'),
                   ',') || ') values ('
                || array_to_string(
                     array_agg(coalesce(
                         quote_literal(ae.old_value), 'NULL'
                     )),
                   ',') ||')'
          when 'U' then
               'UPDATE ' || af.table_schema || '.' || af.table_name || ' set '
               || array_to_string(array_agg(
                    af.column_name||' = '|| coalesce(
                        quote_literal(ae.old_value), 'NULL'
                    )
                  ), ', ') || ' where ' || afpk.column_name || ' = ' 
               || quote_literal(ae.row_pk_val)
          when 'I' then
               'DELETE FROM ' || af.table_schema || '.' || af.table_name || ' where ' 
               || afpk.column_name ||' = '|| quote_literal(ae.row_pk_val)
          end)::varchar as query
     from @extschema@.tb_audit_event ae
     join @extschema@.tb_audit_field af using(audit_field)
     join @extschema@.tb_audit_field afpk on af.table_pk = afpk.audit_field
 group by af.table_schema, af.table_name, ae.row_op, afpk.column_name, 
          ae.row_pk_val, ae.recorded, ae.txid
 order by ae.recorded desc;




-----------------------
------ TRIGGERS -------
-----------------------

-- fn_check_audit_field_validity
CREATE OR REPLACE FUNCTION @extschema@.fn_check_audit_field_validity()
returns trigger as
 $_$
declare
    my_pk_colname       varchar;
begin
    if TG_OP = 'UPDATE' then
        if NEW.table_schema IS DISTINCT FROM OLD.table_schema OR
           NEW.table_name  IS DISTINCT FROM OLD.table_name OR
           NEW.column_name IS DISTINCT FROM OLD.column_name
        then
            raise exception 'Updating table_schema, table_name or column_name not allowed.';
        end if;
    end if;
    
    if NEW.active is null then
        -- set it active if another field in this table is already active
        select active
          into NEW.active
          from @extschema@.tb_audit_field
         where table_name = NEW.table_name
           and table_schema = NEW.table_schema
         order by active desc
         limit 1;
    end if;

    if NEW.active then
        -- active if the column is currently real in the db, inactive otherwise
        select count(*)::integer::boolean
          into NEW.active
          from information_schema.columns
         where table_schema = NEW.table_schema
           and table_name = NEW.table_name
           and column_name = NEW.column_name;
    end if;

    -- We will only set table_pk if it is null, since we
    -- don't want to override values being passed in during a restore
    if NEW.table_pk is null then
        my_pk_colname := @extschema@.fn_get_table_pk_col(NEW.table_name, NEW.table_schema);

        if my_pk_colname is null then
            NEW.table_pk := 0;
        else
            if my_pk_colname = NEW.column_name then
                NEW.table_pk := NEW.audit_field;
            else
                NEW.table_pk := @extschema@.fn_get_or_create_audit_field (
                                    NEW.table_name, 
                                    my_pk_colname,
                                    NEW.table_schema
                                );
            end if;
        end if;
    end if;

    return NEW;
end
 $_$
    language plpgsql;


drop trigger if exists tr_check_audit_field_validity
    on @extschema@.tb_audit_field;

CREATE TRIGGER tr_check_audit_field_validity
    BEFORE INSERT OR UPDATE ON @extschema@.tb_audit_field
    FOR EACH ROW EXECUTE PROCEDURE @extschema@.fn_check_audit_field_validity();


-- fn_audit_event_log_trigger_updater
CREATE OR REPLACE FUNCTION @extschema@.fn_audit_event_log_trigger_updater()
returns trigger as
 $_$
declare
    my_row   record;
begin
    if TG_OP = 'DELETE' then
        my_row := OLD;
    else
        my_row := NEW;
    end if;

    perform c.relname
       from pg_class c
       join pg_namespace n
         on c.relnamespace = n.oid
      where n.nspname = my_row.table_schema
        and c.relname = my_row.table_name;

    -- If table exists, update trigger on the table.
    if found then
        -- Quiet messaeges about truncated names
        set client_min_messages to warning;
        perform @extschema@.fn_update_audit_event_log_trigger_on_table(my_row.table_name, my_row.table_schema);
        set client_min_messages to notice;
    end if;
    return new;
end
 $_$
    language 'plpgsql';


-- drop trigger if exists tr_audit_event_log_trigger_updater
--     on @extschema@.tb_audit_field;

CREATE TRIGGER tr_audit_event_log_trigger_updater
    AFTER INSERT OR UPDATE OR DELETE on @extschema@.tb_audit_field
    FOR EACH ROW EXECUTE PROCEDURE @extschema@.fn_audit_event_log_trigger_updater();



-- EVENT TRIGGER

CREATE OR REPLACE FUNCTION @extschema@.fn_update_audit_fields_event_trigger()
returns event_trigger
language plpgsql as
   $function$
declare
    my_schema   varchar;
begin
    perform @extschema@.fn_update_audit_fields(table_schema)
       from (
                select distinct table_schema
                  from @extschema@.tb_audit_field
                 where audit_field > 0
            ) schemas;
exception
     when insufficient_privilege
     then return;
end
   $function$;

DROP EVENT TRIGGER IF EXISTS tr_update_audit_fields;

CREATE EVENT TRIGGER tr_update_audit_fields ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'CREATE TABLE', 'DROP TABLE')
    EXECUTE PROCEDURE @extschema@.fn_update_audit_fields_event_trigger();



--- PERMISSIONS

grant usage on schema @extschema@ to public;

grant usage on all sequences in schema @extschema@ to public;

grant select on all tables in schema @extschema@ to public;
revoke select on @extschema@.tb_audit_event from public;
grant select on @extschema@.tb_audit_event to postgres;

grant select (audit_transaction_type, txid) 
   on @extschema@.tb_audit_event_current to public;
grant update (audit_transaction_type) 
   on @extschema@.tb_audit_event_current to public;

grant insert on @extschema@.tb_audit_event, 
                @extschema@.tb_audit_event_current,
                @extschema@.tb_audit_transaction_type
        to public;

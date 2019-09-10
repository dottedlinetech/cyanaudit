-- This function is updated in 2.2.1 to better handle an invalid cast exception
--
-- fn_log_audit_event (MAIN LOGGING TRIGGER FUNCTION)
CREATE OR REPLACE FUNCTION cyanaudit.fn_log_audit_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $_$
declare
    my_audit_fields         varchar[];
    my_audit_field          integer;
    my_column_names         varchar[];
    my_column_name          varchar;
    my_new_row              record;
    my_old_row              record;
    my_pk_cols              varchar;
    my_pk_vals_constructor  varchar;
    my_pk_vals              varchar[];
    my_old_value            text;
    my_new_value            text;
    my_clock_timestamp      timestamp;
    my_enabled              text;
    my_exception_text       text;
begin
    my_exception_text := 'cyanaudit: Operation not logged';

    if( TG_OP = 'INSERT' ) then
        my_new_row := NEW;
        my_old_row := NEW;
    elsif( TG_OP = 'UPDATE' ) then
        my_new_row := NEW;
        my_old_row := OLD;
    elsif( TG_OP = 'DELETE' ) then
        my_new_row := OLD;
        my_old_row := OLD;
    end if;

    my_enabled := current_setting( 'cyanaudit.enabled', true );

    if my_enabled = '0' or my_enabled = 'false' or my_enabled = 'f' then
        return my_new_row;
    end if;

    my_pk_cols          := TG_ARGV[0]::varchar[];
    my_audit_fields     := TG_ARGV[1]::varchar[];
    my_column_names     := TG_ARGV[2]::varchar[];

    my_clock_timestamp  := clock_timestamp(); -- same for all entries from this invocation

    -- Bookmark this txid in cyanaudit.last_txid
    perform (set_config('cyanaudit.last_txid', txid_current()::text, false))::bigint;

    -- Given:  my_pk_cols::varchar[]           = ARRAY[ 'column foo',bar ]
    -- Result: my_pk_vals_constructor::varchar = 'select ARRAY[ $1."column foo", $1.bar ]::varchar[]'
    select 'SELECT ARRAY[' || string_agg( '$1.' || quote_ident(pk_col), ',' ) || ']::varchar[]'
      into my_pk_vals_constructor
      from ( select unnest(my_pk_cols::varchar[]) as pk_col ) x;

    -- Execute the result using my_new_row in $1 to produce the following result:
    -- my_pk_vals::varchar[] = ARRAY[ 'val1', 'val2' ]
    execute my_pk_vals_constructor
       into my_pk_vals
      using my_new_row; -- To allow undoing updates to pk columns, logged pk_vals are post-update.

    for my_column_name, my_audit_field in
        select unnest( my_column_names::varchar[] ),
               unnest( my_audit_fields::varchar[] )
    loop
        if TG_OP = 'INSERT' THEN
            EXECUTE format('select null::text, $1.%I::text', my_column_name)
               INTO my_old_value, my_new_value
              USING my_new_row;

            CONTINUE when my_new_value is null;

        elsif TG_OP = 'UPDATE' THEN
            EXECUTE format( 'select $1.%1$I::text, $2.%1$I::text', my_column_name)
               INTO my_old_value, my_new_value
              USING my_old_row, my_new_row;

            CONTINUE when my_old_value is not distinct from my_new_value;

        elsif TG_OP = 'DELETE' THEN
            EXECUTE format('select $1.%I::text, null::text', my_column_name)
               INTO my_old_value, my_new_value
              USING my_old_row;

            CONTINUE when my_old_value is null;

        end if;


        execute format( 'INSERT INTO cyanaudit.tb_audit_event '
                     || '( audit_field, recorded, pk_vals, uid, row_op, audit_transaction_type, old_value, new_value ) '
                     || 'VALUES(  $1, $2, $3, $4, $5::char(1), $6, $7, $8 ) ',
                        my_column_name
                      )
          using my_audit_field,
                my_clock_timestamp,
                my_pk_vals,
                cyanaudit.fn_get_current_uid(),
                TG_OP,
                nullif( current_setting( 'cyanaudit.audit_transaction_type', true ), '' )::integer,
                my_old_value,
                my_new_value;
    end loop;

    return new;
exception
    when foreign_key_violation OR undefined_column then
         raise notice '%: %: %: Please run fn_update_audit_fields().', 
            my_exception_text, SQLSTATE, SQLERRM;
         return my_new_row;
    when undefined_function OR undefined_table OR insufficient_privilege then
         raise notice '%: %: %: Please reinstall cyanaudit.', 
            my_exception_text, SQLSTATE, SQLERRM;
         return my_new_row;
    when invalid_text_representation then
         raise notice '%: %: %: GUC ''cyanaudit.audit_transaction_type'' has non-integer value ''%''. Set with fn_set_transaction_label() or leave unset.',
            my_exception_text, SQLSTATE, SQLERRM,
            current_setting( 'cyanaudit.audit_transaction_type', true );
    when others then
         raise notice '%: %: %: Please report error.', 
            my_exception_text, SQLSTATE, SQLERRM;
         return my_new_row;
end
$_$;

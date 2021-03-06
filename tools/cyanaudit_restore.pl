#!/usr/bin/perl

$|=1;

use strict;
use warnings;
use feature "state";

use DBI;
use Getopt::Std;
use Data::Dumper;
use Time::HiRes qw( gettimeofday );
use File::Basename;
use Parse::CSV;
use Date::Parse;

use lib dirname(__FILE__);

use Cyanaudit;

use constant DEBUG => 1;

sub usage
{
    my( $msg ) = @_;

    warn "Error: $msg\n" if( $msg );
    print "Usage: $0 [ options ] outpath\n"
        . "Options:\n"
        . "  -h host    database server host or socket directory\n"
        . "  -p port    database server port\n"
        . "  -U user    database user name\n"
        . "  -d db      database name\n";

    exit 1;
}

sub microtime()
{
    return sprintf '%d.%0.6d', gettimeofday();
}

sub print_restore_stats($$$)
{
    my( $table_name, $rows_restored, $timestamp ) = @_;

    return unless( DEBUG );

    state (%start_times);

    $start_times{$table_name} = microtime() unless( $start_times{$table_name} );

    my $start_time = $start_times{$table_name};

    my $delta = microtime() - $start_time;
    my $rate = $rows_restored / $delta;
    printf "\r$table_name: Restored %-26s, total %d rows @ %d rows/sec ", 
        $timestamp, $rows_restored, $rate;
}

sub build_db_row_from_csv_row($$)
{
    # $csv_row is a row returned from Parse::CSV
    my( $csv_row, $handle ) = @_;

    return undef unless ( $csv_row->{'old_value'} or $csv_row->{'new_value'} );

    if( $csv_row->{'old_value'} and $csv_row->{'new_value'} )
    {
        return undef if( $csv_row->{'old_value'} eq $csv_row->{'new_value'} );
    }

    my $schema = 'cyanaudit';
    
    state $audit_field_q = "select $schema.fn_get_or_create_audit_field(?,?,?)";
    state $audit_field_sth = $handle->prepare($audit_field_q);

    state $audit_transaction_type_q = "select $schema.fn_get_or_create_audit_transaction_type(?)";
    state $audit_transaction_type_sth = $handle->prepare($audit_transaction_type_q);
    
    state %audit_fields;
    state %audit_transaction_types;

    ### Set audit_field ###
    my $audit_field = $audit_fields{$csv_row->{'table_schema'}}{$csv_row->{'table_name'}}{$csv_row->{'column_name'}};

    unless( $audit_field )
    {
        $audit_field_sth->execute( $csv_row->{'table_schema'}, $csv_row->{'table_name'}, $csv_row->{'column_name'} );
        ($audit_field) = $audit_field_sth->fetchrow_array();
        unless( $audit_field )
        {
            die sprintf( "audit_field %s.%s.%s could not be created/found\n",
                         $csv_row->{'table_schema'}, $csv_row->{'table_name'}, $csv_row->{'column_name'} );
        }
        $audit_fields{$csv_row->{'table_schema'}}{$csv_row->{'table_name'}}{$csv_row->{'column_name'}} = $audit_field;
    }

    ### Set audit_transaction_type ###
    my $audit_transaction_type = undef;
    
    if( $csv_row->{'description'} )
    {
        $audit_transaction_type = $audit_transaction_types{$csv_row->{'description'}};

        unless( $audit_transaction_type )
        {
            $audit_transaction_type_sth->execute( $csv_row->{'description'} );
            ($audit_transaction_type) = $audit_transaction_type_sth->fetchrow_array();
            unless( $audit_transaction_type )
            {
                die sprintf( "audit_transaction_type with label '%s' could not be created/found\n",
                             $csv_row->{'description'} );
            }
            $audit_transaction_types{$csv_row->{'description'}} = $audit_transaction_type;
        }
    }

    state $csv_xs = new Text::CSV_XS;

    $csv_xs->combine(
        $audit_field,
        $csv_row->{'pk_vals'},
        $csv_row->{'recorded'},
        $csv_row->{'uid'},
        $csv_row->{'row_op'},
        $csv_row->{'txid'},
        $audit_transaction_type,
        $csv_row->{'old_value'},
        $csv_row->{'new_value'}
    );

    return $csv_xs->string;
}




my %opts;

getopts( 'U:h:p:d:', \%opts ) or usage();

unless( @ARGV )
{
    usage( "Must specify at least one file to restore" );
}

foreach my $file (@ARGV)
{
    unless( -f $file and -r $file and -s $file )
    {
        usage( "File '$file' is either invalid, unreadable or 0 bytes." );
    }

    unless( basename( $file ) =~ '^tb_audit_event_\d{8}_\d{4}\.csv\.gz$' )
    {
        usage( "$file: Filename must conform to pattern 'tb_audit_event_YYYYMMDD_HHMM.csv.gz\n" );
    }
}

my $handle = db_connect( \%opts )
    or die "Could not connect to database: $DBI::errstr\n";

my $schema = 'cyanaudit';

$handle->do( "SELECT $schema.fn_verify_active_partition()" );

foreach my $file( @ARGV )
{
    print "$file: ";

    open( my $fh, "gunzip -c $file |" ) or die "Could not open $file: $!\n";

    my $csv = Parse::CSV->new(
        handle => $fh,
        names => 1,
        csv_attr => {
            blank_is_undef => 1,
            binary => 1
        },
        filter => sub { 
            if( $_->{'row_pk_val'} )
            {
                $_->{'pk_vals'} = '{' . $_->{'row_pk_val'} . '}';
            }
            unless( $_->{'table_schema'} )
            {
                $_->{'table_schema'} = 'public';
            }
            return $_; 
        }
    );

    (my $table_name = basename( $file ) ) =~ s/\.csv\.gz$//;

    $handle->do( "BEGIN" );

    # Used later on
    $handle->do("SELECT set_config( 'cyanaudit.in_restore', 'true', true )") or die;

    my $create_q = "SELECT $schema.fn_create_new_partition( '$table_name' )";
    my ($table_name_check) = $handle->selectrow_array( $create_q ) or die;

    unless( $table_name_check )
    {
        print "Table already exists, skipping.\n";
        $handle->do("ROLLBACK");
        next;
    }

    $handle->do( "SELECT $schema.fn_archive_partition( '$table_name' )" ) or die;

    my $copy_q = <<SQL;
        COPY $schema.$table_name
        (
            audit_field,
            pk_vals,
            recorded,
            uid,
            row_op,
            txid,
            audit_transaction_type,
            old_value,
            new_value
        ) 
        FROM STDIN WITH ( FORMAT csv, HEADER false )
SQL

    $handle->do( $copy_q );

    my $start_time = microtime();
    my $last_timestamp;

    my %error_rows;

    my $lookup_handle = db_connect( \%opts )
        or die "Could not connect to database: $DBI::errstr\n";

    while( my $row = $csv->fetch )
    {
        my $db_row = build_db_row_from_csv_row( $row, $lookup_handle );

        unless( $db_row )
        {
            $error_rows{$csv->row} = $row;
            next;
        }

        if( $handle->pg_putcopydata($db_row. "\n") != 1 )
        {
            die "pg_putcopydata( " . $db_row . " ) failed: " . DBI::errstr . "\n";
        }

        print_restore_stats( $table_name, $csv->row - 1, $row->{'recorded'} ) unless( ($csv->row - 1) % 1000 );

        $last_timestamp = $row->{'recorded'}
    }

    $handle->pg_putcopyend();

    close( $fh ) or die( "Could not close '$file':\n$!\n" );

    if( $csv->row == 1 )
    {
        print "No data to restore.\n";
        $handle->do("ROLLBACK");
        next;
    }
    else
    {
        print_restore_stats( $table_name, $csv->row - 1, $last_timestamp );
        print "\n";
    }

    print "Setting up partition indexes and constraints...\n" if( DEBUG );

    $handle->do("SELECT $schema.fn_verify_partition_config( '$table_name' )" ) or die;
    $handle->do("SELECT $schema.fn_setup_partition_constraints( '$table_name' )" ) or die;
    $handle->do("SELECT $schema.fn_setup_partition_inheritance( '$table_name' )" ) or die;

    $handle->do( "COMMIT" ) or die;
    my $delta    = ( microtime() - $start_time );
    printf "Processed '$file' in %d:%02d minutes, skipping %d 'no-change' rows\n", 
            $delta/60, $delta%60, scalar keys( %error_rows );
}

print "== DONE ==\nSuccessfully processed " . scalar @ARGV . " files.\n";
exit 0;

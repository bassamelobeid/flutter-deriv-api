BEGIN;
SET search_path = audit, pg_catalog;

CREATE OR REPLACE FUNCTION get_sorted_table_attributes(text, text) RETURNS SETOF record
    LANGUAGE plperlu SECURITY DEFINER
    AS $_X$

    my $schemaname = $_[0];
    my $tablename = $_[1];

    
    my $my_plan = spi_prepare('
     SELECT
       a.attnum,
       a.attname AS field,
       t.typname AS type,
       a.attlen AS length,
       a.atttypmod AS lengthvar,
       a.attnotnull AS notnull
     FROM
       pg_class c,
       pg_attribute a,
       pg_namespace s,
       pg_type t
     WHERE
       c.relname = $1
       AND s.nspname = $2
       AND c.relnamespace = s.oid
       AND a.attnum > 0
       AND a.attrelid = c.oid
       AND a.atttypid = t.oid
       ORDER BY a.attnum;
   ' , ('text', 'text'));
    
    my $family = spi_exec_prepared( 
                $my_plan,
                $tablename,
                $schemaname
                
        )->{rows};
        
        #->{rows}->[0]->{family}
        
        ;

    foreach my $family_record (@{$family}) {
        return_next { 
            attnum => $family_record->{attnum},
            attname => $family_record->{field},
            typname => $family_record->{type},
            attlen => $family_record->{length},
            atttypmod => $family_record->{lengthvar},
            attnotnull => $family_record->{notnull},
        } ;
    }
    
    spi_freeplan( $my_plan);

    return undef;
END;
$_X$;

COMMIT;

#!/bin/bash

set -xe
cd /home/git/bom

rm -rf database/config/sql/rmgdb/old
mkdir  database/config/sql/rmgdb/old

perl -MBOM::Test::Data::Utility::UnitTestDatabase \
     -e 'BOM::Test::Data::Utility::UnitTestDatabase->instance->_migrate_changesets'

rm -f database/config/sql/rmgdb/schema_*.sql~
mv database/config/sql/rmgdb/schema_*.sql database/config/sql/rmgdb/old/

(
    echo 'BEGIN;'
    pg_dump -d regentmarkets -U postgres -T dbix_migration
    echo 'COMMIT;'
) >database/config/sql/rmgdb/schema_1_up.sql

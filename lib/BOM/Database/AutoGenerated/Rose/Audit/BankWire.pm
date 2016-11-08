package BOM::Database::AutoGenerated::Rose::Audit::BankWire;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'bank_wire',
    schema => 'audit',

    columns => [
        operation => {
            type     => 'varchar',
            length   => 10,
            not_null => 1
        },
        stamp => {
            type     => 'timestamp',
            not_null => 1
        },
        pg_userid => {
            type     => 'text',
            not_null => 1
        },
        client_addr => {type => 'scalar'},
        client_port => {type => 'integer'},
        payment_id  => {
            type     => 'bigint',
            not_null => 1
        },
        client_name => {
            type     => 'varchar',
            default  => '',
            length   => 100,
            not_null => 1
        },
        bom_bank_info => {
            type     => 'varchar',
            default  => '',
            length   => 150,
            not_null => 1
        },
        date_received  => {type => 'timestamp'},
        bank_reference => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        bank_name => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        bank_address => {
            type     => 'varchar',
            default  => '',
            length   => 150,
            not_null => 1
        },
        bank_account_number => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        bank_account_name => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        iban => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        sort_code => {
            type     => 'varchar',
            default  => '',
            length   => 150,
            not_null => 1
        },
        swift => {
            type     => 'varchar',
            default  => '',
            length   => 11,
            not_null => 1
        },
        aba => {
            type     => 'varchar',
            default  => '',
            length   => 50,
            not_null => 1
        },
        extra_info => {
            type     => 'varchar',
            default  => '',
            length   => 500,
            not_null => 1
        },
    ],

    primary_key_columns => ['bank_reference'],
);

1;


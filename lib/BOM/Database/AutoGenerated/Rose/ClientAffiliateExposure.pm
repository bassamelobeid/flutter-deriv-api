package BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'client_affiliate_exposure',
    schema => 'betonmarkets',

    columns => [
        id => {
            type     => 'bigint',
            not_null => 1,
            sequence => 'sequences.global_serial'
        },
        client_loginid => {
            type     => 'varchar',
            length   => 12,
            not_null => 1
        },
        myaffiliates_token => {
            type     => 'varchar',
            length   => 32,
            not_null => 1
        },
        exposure_record_date => {
            type    => 'timestamp',
            default => 'now()'
        },
        pay_for_exposure => {
            type     => 'boolean',
            default  => 'false',
            not_null => 1
        },
        myaffiliates_token_registered => {
            type     => 'boolean',
            default  => 'false',
            not_null => 1
        },
        signup_override => {
            type     => 'boolean',
            default  => 'false',
            not_null => 1
        },
    ],

    primary_key_columns => ['id'],

    allow_inline_column_values => 1,

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => {client_loginid => 'loginid'},
        },
    ],
);

1;


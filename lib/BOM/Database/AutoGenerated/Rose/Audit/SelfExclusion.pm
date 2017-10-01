package BOM::Database::AutoGenerated::Rose::Audit::SelfExclusion;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'self_exclusion',
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
        client_addr    => {type => 'scalar'},
        client_port    => {type => 'integer'},
        client_loginid => {
            type     => 'varchar',
            length   => 12,
            not_null => 1
        },
        max_balance            => {type => 'numeric'},
        max_turnover           => {type => 'numeric'},
        max_open_bets          => {type => 'integer'},
        exclude_until          => {type => 'date'},
        session_duration_limit => {type => 'integer'},
        last_modified_date     => {
            type    => 'timestamp',
            default => 'now()'
        },
        max_losses         => {type => 'numeric'},
        max_7day_turnover  => {type => 'numeric'},
        max_7day_losses    => {type => 'numeric'},
        remote_addr        => {type => 'scalar'},
        max_30day_turnover => {type => 'numeric'},
        max_30day_losses   => {type => 'numeric'},
        timeout_until      => {type => 'numeric'},
    ],

    primary_key_columns => ['remote_addr'],

    allow_inline_column_values => 1,
);

1;


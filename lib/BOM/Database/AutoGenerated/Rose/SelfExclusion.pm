package BOM::Database::AutoGenerated::Rose::SelfExclusion;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'self_exclusion',
    schema   => 'betonmarkets',

    columns => [
        client_loginid         => { type => 'varchar', length => 12, not_null => 1 },
        max_balance            => { type => 'numeric' },
        max_turnover           => { type => 'numeric' },
        max_open_bets          => { type => 'integer' },
        exclude_until          => { type => 'date' },
        session_duration_limit => { type => 'integer' },
        last_modified_date     => { type => 'timestamp', default => 'now()' },
        max_losses             => { type => 'numeric' },
        max_7day_turnover      => { type => 'numeric' },
        max_7day_losses        => { type => 'numeric' },
        max_30day_turnover     => { type => 'numeric' },
        max_30day_losses       => { type => 'numeric' },
        timeout_until          => { type => 'numeric' },
        max_deposit_daily      => { type => 'numeric' },
        max_deposit_7day       => { type => 'numeric' },
        max_deposit_30day      => { type => 'numeric' },
    ],

    primary_key_columns => [ 'client_loginid' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
            rel_type    => 'one to one',
        },
    ],
);

1;


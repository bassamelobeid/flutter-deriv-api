package BOM::Database::AutoGenerated::Rose::PaymentAgent;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'payment_agent',
    schema   => 'betonmarkets',

    columns => [
        client_loginid        => { type => 'varchar', length => 12, not_null => 1 },
        payment_agent_name    => { type => 'varchar', length => 100, not_null => 1 },
        url                   => { type => 'varchar', length => 100, not_null => 1 },
        email                 => { type => 'varchar', length => 100, not_null => 1 },
        phone                 => { type => 'varchar', length => 40, not_null => 1 },
        information           => { type => 'varchar', length => 500, not_null => 1 },
        summary               => { type => 'varchar', length => 255, not_null => 1 },
        commission_deposit    => { type => 'numeric', not_null => 1 },
        commission_withdrawal => { type => 'numeric', not_null => 1 },
        is_authenticated      => { type => 'boolean', not_null => 1 },
        api_ip                => { type => 'varchar', length => 64 },
        currency_code         => { type => 'text', not_null => 1 },
        target_country        => { type => 'varchar', default => '', length => 255, not_null => 1 },
        supported_banks       => { type => 'varchar', length => 500 },
        min_withdrawal        => { type => 'numeric' },
        max_withdrawal        => { type => 'numeric' },
        is_listed             => { type => 'boolean', default => 'true', not_null => 1 },
        code_of_conduct_approval => { type => 'boolean'},
        affiliate_id          => { type => 'varchar', length => 100 },
    ],

    primary_key_columns => [ 'client_loginid' ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
            rel_type    => 'one to one',
        },
    ],
);

1;


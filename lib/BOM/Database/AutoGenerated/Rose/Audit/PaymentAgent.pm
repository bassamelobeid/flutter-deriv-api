package BOM::Database::AutoGenerated::Rose::Audit::PaymentAgent;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'payment_agent',
    schema   => 'audit',

    columns => [
        operation             => { type => 'varchar', length => 10, not_null => 1 },
        stamp                 => { type => 'timestamp', not_null => 1 },
        pg_userid             => { type => 'text', not_null => 1 },
        client_addr           => { type => 'scalar' },
        client_port           => { type => 'integer' },
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
        currency_code         => { type => 'varchar', length => 3, not_null => 1 },
        target_country        => { type => 'varchar', default => '', length => 255, not_null => 1 },
        supported_banks       => { type => 'varchar', length => 500 },
        remote_addr           => { type => 'scalar' },
        min_withdrawal        => { type => 'numeric' },
        max_withdrawal        => { type => 'numeric' },
    ],

    primary_key_columns => [ 'remote_addr' ],
);

1;


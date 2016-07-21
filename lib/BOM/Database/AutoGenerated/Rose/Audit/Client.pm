package BOM::Database::AutoGenerated::Rose::Audit::Client;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client',
    schema   => 'audit',

    columns => [
        operation                                => { type => 'varchar', length => 10, not_null => 1 },
        stamp                                    => { type => 'timestamp', not_null => 1 },
        pg_userid                                => { type => 'text', not_null => 1 },
        client_addr                              => { type => 'scalar' },
        client_port                              => { type => 'integer' },
        loginid                                  => { type => 'varchar', length => 12, not_null => 1 },
        client_password                          => { type => 'varchar', length => 255, not_null => 1 },
        first_name                               => { type => 'varchar', length => 50, not_null => 1 },
        last_name                                => { type => 'varchar', length => 50, not_null => 1 },
        email                                    => { type => 'varchar', length => 100, not_null => 1 },
        allow_login                              => { type => 'boolean', default => 'true', not_null => 1 },
        broker_code                              => { type => 'varchar', length => 32, not_null => 1 },
        residence                                => { type => 'varchar', length => 100, not_null => 1 },
        citizen                                  => { type => 'varchar', length => 100, not_null => 1 },
        salutation                               => { type => 'varchar', length => 30, not_null => 1 },
        address_line_1                           => { type => 'varchar', length => 1000, not_null => 1 },
        address_line_2                           => { type => 'varchar', length => 255, not_null => 1 },
        address_city                             => { type => 'varchar', length => 300, not_null => 1 },
        address_state                            => { type => 'varchar', length => 100, not_null => 1 },
        address_postcode                         => { type => 'varchar', length => 64, not_null => 1 },
        phone                                    => { type => 'varchar', length => 255, not_null => 1 },
        date_joined                              => { type => 'timestamp', default => 'now()' },
        latest_environment                       => { type => 'varchar', length => 1024, not_null => 1 },
        secret_question                          => { type => 'varchar', length => 255, not_null => 1 },
        secret_answer                            => { type => 'varchar', length => 500, not_null => 1 },
        restricted_ip_address                    => { type => 'varchar', length => 50, not_null => 1 },
        gender                                   => { type => 'varchar', length => 1, not_null => 1 },
        cashier_setting_password                 => { type => 'varchar', length => 255, not_null => 1 },
        date_of_birth                            => { type => 'date' },
        small_timer                              => { type => 'varchar', default => 'yes', length => 30, not_null => 1 },
        comment                                  => { type => 'text', default => '', not_null => 1 },
        myaffiliates_token                       => { type => 'varchar', length => 32 },
        myaffiliates_token_registered            => { type => 'boolean', default => 'false', not_null => 1 },
        checked_affiliate_exposures              => { type => 'boolean', default => 'false', not_null => 1 },
        custom_max_acbal                         => { type => 'integer' },
        custom_max_daily_turnover                => { type => 'integer' },
        custom_max_payout                        => { type => 'integer' },
        vip_since                                => { type => 'timestamp' },
        payment_agent_withdrawal_expiration_date => { type => 'date' },
        first_time_login                         => { type => 'boolean', default => 'true' },
        source                                   => { type => 'varchar', length => 50 },
        remote_addr                              => { type => 'scalar' },
        occupation                               => { type => 'varchar', length => 100 },
        aml_risk_classification                  => { type => 'enum', check_in => [ 'low', 'standard', 'high', 'manual override - low', 'manual override - standard', 'manual override - high' ], db_type => 'aml_risk_type', default => 'low' },
        allow_omnibus                            => { type => 'boolean' },
        sub_account_of                           => { type => 'varchar', length => 12 },
    ],

    primary_key_columns => [ 'custom_max_payout' ],

    allow_inline_column_values => 1,
);

1;

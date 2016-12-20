package BOM::Database::AutoGenerated::Rose::Client;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client',
    schema   => 'betonmarkets',

    columns => [
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
        allow_copiers                            => { type => 'boolean', default => 'false' },
        custom_max_acbal                         => { type => 'integer' },
        custom_max_daily_turnover                => { type => 'integer' },
        custom_max_payout                        => { type => 'integer' },
        vip_since                                => { type => 'timestamp' },
        payment_agent_withdrawal_expiration_date => { type => 'date' },
        first_time_login                         => { type => 'boolean', default => 'true' },
        source                                   => { type => 'varchar', length => 50 },
        occupation                               => { type => 'varchar', length => 100 },
        aml_risk_classification                  => { type => 'enum', check_in => [ 'low', 'standard', 'high', 'manual override - low', 'manual override - standard', 'manual override - high' ], db_type => 'aml_risk_type', default => 'low' },
        allow_omnibus                            => { type => 'boolean' },
        sub_account_of                           => { type => 'varchar', length => 12 },
    ],

    primary_key_columns => [ 'loginid' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        broker_code_obj => {
            class       => 'BOM::Database::AutoGenerated::Rose::BrokerCode',
            key_columns => { broker_code => 'broker_code' },
        },

        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { sub_account_of => 'loginid' },
        },
    ],

    relationships => [
        client_affiliate_exposure => {
            class      => 'BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure',
            column_map => { loginid => 'client_loginid' },
            type       => 'one to many',
        },

        client_authentication_document => {
            class      => 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument',
            column_map => { loginid => 'client_loginid' },
            type       => 'one to many',
        },

        client_authentication_method => {
            class      => 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod',
            column_map => { loginid => 'client_loginid' },
            type       => 'one to many',
        },

        client_lock => {
            class                => 'BOM::Database::AutoGenerated::Rose::ClientLock',
            column_map           => { loginid => 'client_loginid' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        client_objs => {
            class      => 'BOM::Database::AutoGenerated::Rose::Client',
            column_map => { loginid => 'sub_account_of' },
            type       => 'one to many',
        },

        client_promo_code => {
            class                => 'BOM::Database::AutoGenerated::Rose::ClientPromoCode',
            column_map           => { loginid => 'client_loginid' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        client_status => {
            class      => 'BOM::Database::AutoGenerated::Rose::ClientStatus',
            column_map => { loginid => 'client_loginid' },
            type       => 'one to many',
        },

        financial_assessment => {
            class                => 'BOM::Database::AutoGenerated::Rose::FinancialAssessment',
            column_map           => { loginid => 'client_loginid' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        login_history => {
            class      => 'BOM::Database::AutoGenerated::Rose::LoginHistory',
            column_map => { loginid => 'client_loginid' },
            type       => 'one to many',
        },

        payment_agent => {
            class                => 'BOM::Database::AutoGenerated::Rose::PaymentAgent',
            column_map           => { loginid => 'client_loginid' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        self_exclusion => {
            class                => 'BOM::Database::AutoGenerated::Rose::SelfExclusion',
            column_map           => { loginid => 'client_loginid' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },
    ],
);

1;


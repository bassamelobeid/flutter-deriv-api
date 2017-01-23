package BOM::Database::AutoGenerated::Rose::Payment;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'payment',
    schema   => 'payment',

    columns => [
        id                   => { type => 'bigint', not_null => 1, sequence => 'sequences.payment_serial' },
        payment_time         => { type => 'timestamp', default => 'now()' },
        amount               => { type => 'numeric', not_null => 1, precision => 12, scale => 24 },
        payment_gateway_code => { type => 'varchar', length => 50, not_null => 1 },
        payment_type_code    => { type => 'varchar', length => 50, not_null => 1 },
        status               => { type => 'varchar', length => 20, not_null => 1 },
        account_id           => { type => 'bigint', not_null => 1 },
        staff_loginid        => { type => 'varchar', length => 12, not_null => 1 },
        remark               => { type => 'varchar', default => '', length => 800, not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        payment_gateway => {
            class       => 'BOM::Database::AutoGenerated::Rose::PaymentGateway',
            key_columns => { payment_gateway_code => 'code' },
        },

        payment_type => {
            class       => 'BOM::Database::AutoGenerated::Rose::PaymentType',
            key_columns => { payment_type_code => 'code' },
        },
    ],

    relationships => [
        account_transfer => {
            class                => 'BOM::Database::AutoGenerated::Rose::AccountTransfer',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        account_transfer_objs => {
            class      => 'BOM::Database::AutoGenerated::Rose::AccountTransfer',
            column_map => { id => 'corresponding_payment_id' },
            type       => 'one to many',
        },

        affiliate_reward => {
            class                => 'BOM::Database::AutoGenerated::Rose::AffiliateReward',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        arbitrary_markup => {
            class                => 'BOM::Database::AutoGenerated::Rose::ArbitraryMarkup',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        bank_wire => {
            class                => 'BOM::Database::AutoGenerated::Rose::BankWire',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        currency_conversion_transfer => {
            class                => 'BOM::Database::AutoGenerated::Rose::CurrencyConversionTransfer',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        currency_conversion_transfer_objs => {
            class      => 'BOM::Database::AutoGenerated::Rose::CurrencyConversionTransfer',
            column_map => { id => 'corresponding_payment_id' },
            type       => 'one to many',
        },

        doughflow => {
            class                => 'BOM::Database::AutoGenerated::Rose::Doughflow',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        epg => {
            class                => 'BOM::Database::AutoGenerated::Rose::Epg',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        free_gift => {
            class                => 'BOM::Database::AutoGenerated::Rose::FreeGift',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        legacy_payment => {
            class                => 'BOM::Database::AutoGenerated::Rose::LegacyPayment',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        payment_agent_transfer => {
            class                => 'BOM::Database::AutoGenerated::Rose::PaymentAgentTransfer',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        payment_agent_transfer_objs => {
            class      => 'BOM::Database::AutoGenerated::Rose::PaymentAgentTransfer',
            column_map => { id => 'corresponding_payment_id' },
            type       => 'one to many',
        },

        payment_fee => {
            class                => 'BOM::Database::AutoGenerated::Rose::PaymentFee',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        payment_fee_objs => {
            class      => 'BOM::Database::AutoGenerated::Rose::PaymentFee',
            column_map => { id => 'corresponding_payment_id' },
            type       => 'one to many',
        },

        western_union => {
            class                => 'BOM::Database::AutoGenerated::Rose::WesternUnion',
            column_map           => { id => 'payment_id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },
    ],
);

1;


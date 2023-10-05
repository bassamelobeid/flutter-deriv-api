#!/usr/bin/perl

use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::FailWarnings;
use Test::MockModule;
use Test::Exception;

use Future::AsyncAwait;
use Commission::Calculator;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->quants->dxtrade_affiliate_commission->enable(1);

my $mocked_calc = Test::MockModule->new('Commission::Calculator');

my @test_cases = ({
        name                       => 'invalid symbol is skipped',
        _get_effective_deals_count => 1,
        _get_deals_per_page        => [{
                id                  => '123:1234',
                provider            => 'dxtrade',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 1',
                volume              => 1,
                spread              => 0,
                price               => 6484.719,
                currency            => 'USD',
                payment_currency    => 'USD',
                performed_at        => '2021-06-28 10:00:00'
            }
        ],
        _make_affiliate_payment => [],
        _config_commission_rate => {standard => {R_10 => {'volume' => 0.0001}}},
        expected_store          => []
    },
    {
        name                       => 'undef exchange rate',
        _get_effective_deals_count => 1,
        _get_deals_per_page        => [{
                id                  => '123:1234',
                provider            => 'dxtrade',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 10',
                volume              => 1,
                spread              => 0,
                price               => 6484.719,
                currency            => 'USD',
                payment_currency    => 'RUB',
                performed_at        => '2021-06-28 10:00:00'
            }
        ],
        _make_affiliate_payment => [],
        _config_commission_rate => {standard => {R_10 => {'volume' => 0.0001}}},
        expected_store          => []
    },
    {
        name                       => 'undef exchange rate',
        _get_effective_deals_count => 1,
        _get_deals_per_page        => [{
                id                  => '123:1234',
                provider            => 'dxtrade',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 10',
                volume              => 1,
                spread              => 0,
                price               => 6484.719,
                currency            => 'USD',
                payment_currency    => 'RUB',
                performed_at        => '2021-06-28 10:00:00'
            }
        ],
        _make_affiliate_payment => [],
        _config_commission_rate => {standard => {R_10 => {'volume' => 0.0001}}},
        expected_store          => []
    },
    {
        name                       => 'undef commission rate',
        _get_effective_deals_count => 1,
        _get_deals_per_page        => [{
                id                  => '123:1234',
                provider            => 'fake_provider',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 10',
                volume              => 1,
                spread              => 0,
                price               => 6484.719,
                currency            => 'USD',
                payment_currency    => 'USD',
                performed_at        => '2021-06-28 10:00:00'
            }
        ],
        _make_affiliate_payment => [],
        _config_commission_rate => {standard => {R_10 => {'volume' => 0.0001}}},
        expected_store          => []
    },
    {
        name                       => 'successful 2 deals',
        _get_effective_deals_count => 2,
        _get_deals_per_page        => [{
                id                  => '123:1234',
                provider            => 'dxtrade',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 10',
                volume              => 1,
                spread              => 0,
                price               => 6484.719,
                currency            => 'USD',
                payment_currency    => 'USD',
                performed_at        => '2021-06-28 10:00:00'
            },
            {
                id                  => '123:1235',
                provider            => 'dxtrade',
                affiliate_client_id => 1,
                account_type        => 'standard',
                symbol              => 'Vol 10',
                volume              => 1,
                spread              => 0,
                price               => 6484.819,
                currency            => 'USD',
                payment_currency    => 'USD',
                performed_at        => '2021-06-28 10:10:00'
            }
        ],
        _make_affiliate_payment => [],
        _config_commission_rate => {standard => {'Vol 10' => {'volume' => '0.0000075'}}},
        expected_store          => [{
                commission_type       => 'volume',
                'exchange_rate'       => 1,
                'mapped_symbol'       => 'Vol 10',
                'price'               => '6484.719',
                'applied_commission'  => '0.0000075',
                'provider'            => 'dxtrade',
                'amount'              => '0.0486353925',
                'base_symbol'         => 'Vol 10',
                'performed_at'        => '2021-06-28 10:00:00',
                'calculated_at'       => ignore(),
                'exchange_rate_ts'    => ignore(),
                'affiliate_client_id' => 1,
                'target_currency'     => 'USD',
                'account_type'        => 'standard',
                'deal_id'             => '123:1234',
                'volume'              => 1,
                'base_currency'       => 'USD',
                'base_amount'         => '0.0486353925',
                spread                => 0,
            },
            {
                commission_type       => 'volume',
                'provider'            => 'dxtrade',
                'applied_commission'  => '0.0000075',
                'mapped_symbol'       => 'Vol 10',
                'price'               => '6484.819',
                'exchange_rate'       => 1,
                'base_currency'       => 'USD',
                'volume'              => 1,
                'account_type'        => 'standard',
                'deal_id'             => '123:1235',
                'target_currency'     => 'USD',
                'affiliate_client_id' => 1,
                'exchange_rate_ts'    => ignore(),
                'performed_at'        => '2021-06-28 10:10:00',
                'calculated_at'       => ignore(),
                'base_symbol'         => 'Vol 10',
                'amount'              => '0.0486361425',
                'base_amount'         => '0.0486361425',
                spread                => 0,
            },
        ],
    },
);

foreach my $case (@test_cases) {
    my $stored = [];
    $mocked_calc->mock('_make_affiliate_payment',    async sub { return $case->{_make_affiliate_payment} });
    $mocked_calc->mock('_config_commission_rate',    async sub { return $case->{_config_commission_rate} });
    $mocked_calc->mock('_get_effective_deals_count', async sub { return $case->{_get_effective_deals_count} });
    $mocked_calc->mock(
        '_get_deals_per_page',
        async sub {
            return $case->{_get_deals_per_page};
        });
    $mocked_calc->mock(
        '_store_calculated_commission',
        async sub {
            my (undef, %args) = @_;
            push @$stored, \%args;
        });

    subtest 'test commission calculation' => sub {
        my $loop = IO::Async::Loop->new;
        my $calc = Commission::Calculator->new(
            db_service         => 'test',
            cfd_provider       => 'dxtrade',
            affiliate_provider => 'myaffiliate',
            date               => '2021-06-28'
        );
        $loop->add($calc);
        $calc->calculate->get();
        cmp_deeply $stored, $case->{expected_store}, 'expected store count for case[' . $case->{name} . ']';
    };
}

subtest "Test new input param [from_date] for script" => sub {

    lives_ok {
        my $calc = Commission::Calculator->new(
            db_service         => 'test',
            cfd_provider       => 'test_provider',
            affiliate_provider => 'myaffiliate',
            date               => '2021-06-28',
            from_date          => '2021-06-12'
        );
    }
    'Should not die when given correct from_date format';

    dies_ok {
        my $calc = Commission::Calculator->new(
            db_service         => 'test',
            cfd_provider       => 'test_provider',
            affiliate_provider => 'myaffiliate',
            date               => '2021-06-28',
            from_date          => 'ABC-420-12'
        );
    }
    "Should die when from_date is not a valid date";

    dies_ok {
        my $future_date = Date::Utility->new();
        $future_date->add_days(1);    # add 1 day to the current date
        my $calc = Commission::Calculator->new(
            db_service         => 'test',
            cfd_provider       => 'test_provider',
            affiliate_provider => 'myaffiliate',
            date               => '2021-06-28',
            from_date          => $future_date
        );
    }
    "Should die when from_date is a future date";

};

done_testing();

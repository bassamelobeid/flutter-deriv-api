package BOM::Test::Mock::Exchanges;
use 5.010;
use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestCouchDB;

my %exchange = (
    ASX      => undef,
    ASX_S    => undef,
    ASX_F    => undef,
    BI       => undef,
    BM       => undef,
    BSE      => undef,
    CME      => undef,
    EUREX    => undef,
    EURONEXT => {
        delay_amount => 20,
        market_times => {
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m',
            },
        },
    },
    FOREX => undef,
    FSE   => {
        delay_amount => 15,
    },
    FSEEURONEXT => undef,
    FSELSE      => undef,
    FSESBF      => undef,
    FSESWS      => undef,
    FSEBI       => undef,
    HKSE        => {
        delay_amount => 60,
    },
    ISE          => undef,
    JSC          => undef,
    JSE          => undef,
    KRX          => undef,
    LSE          => undef,
    FS           => undef,
    NASDAQ       => undef,
    NASDAQ_INDEX => undef,
    NSE          => undef,
    NYSE         => {
        currency         => 'USD',
        trading_timezone => 'America/New_York',
        market_times     => {
            dst => {
                daily_close      => '20h',
                daily_open       => '13h30m',
                daily_settlement => '22h59m59s',
            },
            standard => {
                daily_close      => '21h',
                daily_open       => '14h30m',
                daily_settlement => '23h59m59s',
            },
        },
    },
    NYSE_SPC        => undef,
    NZSE            => undef,
    MEFF            => undef,
    ODLS            => undef,
    OMX             => undef,
    RANDOM          => undef,
    RANDOM_NOCTURNE => undef,
    SBF             => undef,
    SGX             => undef,
    SES             => undef,
    SFE             => undef,
    SWX             => undef,
    SSE             => undef,
    SZSE            => undef,
    TRSE            => undef,
    TSE             => {
        trading_timezone => 'Asia/Tokyo',
        currency         => 'JPY',
        market_times     => {
            early_closes => {},
            standard     => {
                afternoon_open   => '3h30m',
                daily_close      => '6h',
                daily_open       => '0s',
                morning_close    => '2h30m',
                daily_settlement => '9h',
            },
            partial_trading => {},
        },
    },
    TSE_S     => undef,
    BOVESPA   => undef,
    OSLO      => undef,
    SP_GLOBAL => undef,
    SP_GSCI   => undef,
    RTS       => undef,
);

sub import {
    my $class = shift;
    _init() if grep { /^:init$/ } @_;

    return;
}

sub _init {
    for (keys %exchange) {
        if ($exchange{$_}) {
            BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
                'exchange',
                {
                    symbol => $_,
                    date   => Date::Utility->new->datetime_iso8601,
                    %{$exchange{$_}},
                });
        } else {
            BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
                'exchange',
                {
                    symbol => $_,
                    date   => Date::Utility->new->datetime_iso8601,
                });
        }
    }

    return;
}

1;

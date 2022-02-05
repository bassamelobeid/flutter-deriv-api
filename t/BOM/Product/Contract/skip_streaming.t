#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Registry;

my $args = {
    duration => '5m',
    barrier  => 'S0P',
    currency => 'USD',
    payout   => 100
};

subtest 'non-synthetic callput ATM' => sub {
    foreach my $bet_type (qw(CALL CALLE)) {
        $args->{bet_type} = $bet_type;
        foreach my $symbol (qw(frxUSDJPY OTC_AS51 frxXAUUSD WLDUSD)) {
            $args->{underlying} = $symbol;
            my $contract = produce_contract($args);
            ok !$contract->skip_streaming, 'do not skip price streaming for ' . $symbol . ' ATM ' . $bet_type;
        }
    }

};

subtest 'synthetic' => sub {
    my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings({
        loaded_revision => 0,
        action          => 'buy'
    });
    my @symbols = map { $offerings->query({submarket => $_}, ['underlying_symbol']) } qw(random_index random_daily);

    subtest 'touchnotouch' => sub {
        $args->{barrier} = 'S20P';
        foreach my $bet_type (qw(NOTOUCH ONETOUCH)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok !$contract->skip_streaming, 'do not skip price streaming for ' . $symbol . ' ' . $bet_type;
            }
        }
    };

    subtest '5m non-ATM callput(equal)' => sub {
        $args->{barrier} = 'S20P';
        foreach my $bet_type (qw(CALL PUT CALLE PUTE)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok !$contract->skip_streaming, 'do not skip price streaming for ' . $symbol . ' non-ATM ' . $bet_type;
            }
        }
    };

    subtest '5m ATM callput(equal)' => sub {
        $args->{barrier} = 'S0P';
        foreach my $bet_type (qw(CALL PUT CALLE PUTE)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok $contract->skip_streaming, 'skip price streaming for 5m ' . $symbol . ' ATM ' . $bet_type;
            }
        }
    };

    subtest '5t ATM callput(equal)' => sub {
        $args->{duration} = '5t';
        $args->{barrier}  = 'S0P';
        foreach my $bet_type (qw(CALL PUT CALLE PUTE)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok $contract->skip_streaming, 'skip price streaming for 5t ' . $symbol . ' ATM ' . $bet_type;
            }
        }
    };

    subtest '1d ATM callput(equal)' => sub {
        $args->{duration} = '1d';
        $args->{barrier}  = 'S0P';
        foreach my $bet_type (qw(CALL PUT CALLE PUTE)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok !$contract->skip_streaming, 'do not skip price streaming for 1d ' . $symbol . ' ATM ' . $bet_type;
            }
        }
    };

    subtest 'other tick product' => sub {
        $args->{duration} = '5t';
        foreach my $bet_type (qw(RESETCALL RESETPUT)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok $contract->skip_streaming, 'skip price streaming for 5t ' . $symbol . ' ' . $bet_type;
            }
        }
        delete $args->{barrier};
        foreach my $bet_type (qw(ASIANU ASIAND DIGITODD DIGITEVEN)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok $contract->skip_streaming, 'skip price streaming for 5t ' . $symbol . ' ' . $bet_type;
            }
        }

        $args->{selected_tick} = 5;
        foreach my $bet_type (qw(TICKHIGH TICKLOW)) {
            $args->{bet_type} = $bet_type;
            foreach my $symbol (@symbols) {
                $args->{underlying} = $symbol;
                my $contract = produce_contract($args);
                ok $contract->skip_streaming, 'skip price streaming for 5t ' . $symbol . ' ' . $bet_type;
            }
        }
    };
};

done_testing();

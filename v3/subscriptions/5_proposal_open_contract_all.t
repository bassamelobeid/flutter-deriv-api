#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Future::Utils qw( fmap0 );
use feature qw(state);

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );
use BOM::Test::WebsocketAPI::Parameters qw( clients );

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 300,
        max_response_delay => 10,
        suite_params       => {
            concurrent => 50,
        },
    ),
);

subtest "Proposal open contract - no contract id" => sub {
    Future->needs_all(
        map {
            ;
            $tester->poc_no_contract_id(
                requests => requests(
                    client => $_,
                    calls  => [qw(buy)],
                    filter => sub {
                        shift->{params}->contract->underlying->symbol =~ /R_.*|frxUSD.*/;
                    }
                ),
                token => $_->token,
                )
        } clients()->@*
    )->get;
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';
use Future::Utils qw( fmap0 );
use feature qw( state );

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        suite_params => {
            requests => requests(
                filter => sub {
                    state $count;
                    my $params = delete $_[0]->{params};
                    ++$count->{$_[0]->{request}} == 1;
                },
            ),
        }
    ),
);

subtest 'Publish gap test - all calls in parallel' => sub {
    $tester->publish_gap->get;
};

done_testing;

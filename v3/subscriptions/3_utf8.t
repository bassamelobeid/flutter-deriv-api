#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;

my $loop = IO::Async::Loop->new;
$loop->add(my $tester = BOM::Test::WebsocketAPI->new,);

$tester->check_utf8_fields_work->get;

done_testing();

1;

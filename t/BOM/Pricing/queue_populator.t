#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Pricing::QueuePopulator::Japan;

subtest 'it runs' => sub {
    my $pop = BOM::Pricing::QueuePopulator::Japan->new;
    lives_ok {$pop->process} 'does not die';
};

done_testing();

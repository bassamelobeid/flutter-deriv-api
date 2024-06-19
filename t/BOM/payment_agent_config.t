#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;

local $ENV{BOM_TEST_CONFIG} = 't/';
subtest 'General' => sub {
    use_ok('BOM::Config::PaymentAgent', 'Loaded module OK');

};

subtest 'Transfer limits - validation' => sub {
    like(
        exception { BOM::Config::PaymentAgent::get_transfer_min_max('') },
        qr/No currency is specified for PA limits/,
        'Correct exception for empty currency'
    );
    like(
        exception { BOM::Config::PaymentAgent::get_transfer_min_max('XYZ') },
        qr/Invalid currency XYZ for PA limits/,
        'Correct exception for invalid currency'
    );
};

subtest 'Transfer_limits Specific Currency' => sub {
    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max('UST');
    is($min_max->{maximum}, 3000, 'Correct Maximum for specific Currency');
    is($min_max->{minimum}, 3,    'Correct Minimum for specific Currency');
};
subtest 'Transfer_limits Default' => sub {
    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max('USD');
    is($min_max->{maximum}, 2000, 'Correct Maximum for specific Currency');
    is($min_max->{minimum}, 10,   'Correct Minimum for specific Currency');
};
done_testing();
1;


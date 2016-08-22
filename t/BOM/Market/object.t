use strict;
use warnings;

use Test::Most tests => 3;
use Test::Exception;
use Test::FailWarnings;

use BOM::Market;
use BOM::Market::Registry;

throws_ok { BOM::Market->new() } qr/Attribute \(name\) is required/, 'Name is Required';

subtest 'disabled' => sub {
    subtest 'simple' => sub {
        my $bfm = new_ok('BOM::Market' => [{'name' => 'forex'}]);
        ok !$bfm->disabled, 'Forex Not disabled';
    };
};

subtest 'disable_iv' => sub {
    BOM::Platform::Runtime->instance->app_config->quants->markets->disable_iv(['stocks']);
    my $bfm = new_ok('BOM::Market' => [{'name' => 'stocks'}]);
    ok $bfm->disable_iv;

    $bfm = new_ok('BOM::Market' => [{'name' => 'forex'}]);
    ok !$bfm->disable_iv;
};

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use Test::Output qw(:functions);
use Test::Warn;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

subtest 'has_funded' => sub {
    subtest 'CR001 - no funding' => sub {
        my $client = BOM::Platform::Client::get_instance({loginid => 'CR0001'});
        ok !$client->has_deposits({exclude => ['free_gift']}), 'never deposited, if free gifts are excluded';
        ok !$client->has_deposits(), 'never deposited';
        ok !$client->has_funded(),   'never funded';
    };

    subtest 'CR0005 - has funded' => sub {
        my $client = BOM::Platform::Client::get_instance({loginid => 'CR0005'});
        ok $client->has_deposits(), 'deposited';
        ok $client->has_deposits({exclude => ['free_gift']}), 'deposited, even if free gifts are excluded';
        ok $client->has_funded(), 'A non free deposit so funded';
    };

    subtest 'CR0006 - free loader' => sub {
        my $client = BOM::Platform::Client::get_instance({loginid => 'CR0006'});
        ok $client->has_deposits(), 'Yaay! funded';
        ok !$client->has_deposits({exclude => ['free_gift']}), 'wait, it was a free gift from us';
        ok !$client->has_funded(), 'No non free deposit so not funded';
    };
};

#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Test::Helper                          qw/test_schema build_wsapi_test build_test_R_50_data build_mojo_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;

my $t = build_wsapi_test();

my $email = 'mf_client@deriv.com';
my $user  = BOM::User->create(
    email    => $email,
    password => '1234'
);

my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'gb',
    email       => $email
});

my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    residence   => 'gb',
    email       => $email
});

$mf_client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

$user->add_client($mf_client);
$user->add_client($vr_client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

subtest 'Authorization' => sub {
    my $data = $t->await::balance({balance => 1, account => 'all'});
    ok $data->{error}, 'There is an error';
    is $data->{error}->{code},    'AuthorizationRequired';
    is $data->{error}->{message}, 'Please log in.';

    $t->await::authorize({authorize => $token});

    $data = $t->await::balance({balance => 1, account => 'all'});
    ok($data->{balance}, "got balance");
    ok !$data->{error}, 'No error';
    test_schema('balance', $data);
};

subtest 'Subscribe to balance (all)' => sub {
    my $data = $t->await::balance({balance => 1, account => 'all', subscribe => 1});

    my $res_id = $data->{balance}->{id};
    ok($data->{balance}, "got balance");
    is $data->{subscription}->{id}, $res_id, 'Got correct Subscription id';
    test_schema('balance', $data);

    $data = $t->await::forget_all({forget_all => 'balance'});
    is(scalar @{$data->{forget_all}}, 1, 'Correct number of subscriptions');
    is $data->{forget_all}->[0], $res_id, 'Correct subscription id';
};

done_testing;

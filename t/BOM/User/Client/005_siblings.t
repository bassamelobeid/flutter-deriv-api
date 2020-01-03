#!/etc/rmg/bin/perl
package t::BOM::User::Client;

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::Password;

sub create_user {
    my $hash_pwd = BOM::User::Password::hashpw('passW0rd');
    my $email    = 'test' . rand(999) . '@binary.com';

    return BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
}

sub create_client {
    my $user     = shift;
    my $currency = shift;

    my $client_details = {
        broker_code     => 'CR',
        residence       => 'au',
        client_password => 'x',
        last_name       => 'shuwnyuan',
        first_name      => 'tee',
        email           => 'shuwnyuan@regentmarkets.com',
        salutation      => 'Ms',
        address_line_1  => 'ADDR 1',
        address_city    => 'Segamat',
        phone           => '+60123456789',
        secret_question => "Mother's maiden name",
        secret_answer   => 'blah',
    };

    my $client = $user->create_client(%$client_details, @_);
    $client->set_default_account($currency);

    return $client;
}

subtest 'arguments are checked before using' => sub {
    my $user        = create_user();
    my $usd_client  = create_client($user, 'USD');
    my $status_code = 'disabled';

    dies_ok sub { $usd_client->copy_status_to_siblings() }, 'Without arguments';
    dies_ok sub { $usd_client->copy_status_to_siblings($status_code) }, 'Without staff name';

    my $usd_client_loginid = $usd_client->loginid;
    throws_ok sub { $usd_client->copy_status_to_siblings($status_code, 'user01') },
        qr/$usd_client_loginid: Can't copy $status_code to its siblings because it hasn't been set yet/,
        'Status code that has not been set to the current client';
};

subtest 'copy_status_to_siblings' => sub {
    my $status_code = 'withdrawal_locked';

    my $user       = create_user();
    my $usd_client = create_client($user, 'USD');
    my $btc_client = create_client($user, 'BTC');
    my $eth_client = create_client($user, 'ETH');

    $usd_client->status->set($status_code, 'user01', 'reason');

    # prerequisites
    ok $usd_client->status->$status_code, "USD client has been set with $status_code";
    is $btc_client->status->$status_code, undef, "BTC client has NOT been set with $status_code";
    is $eth_client->status->$status_code, undef, "ETH client has NOT been set with $status_code";
    # /prerequisites

    cmp_bag(
        $usd_client->copy_status_to_siblings($status_code, 'user02'),
        [$btc_client->loginid, $eth_client->loginid],
        'returns an array with the loginid of the updated siblings'
    );

    cmp_bag($usd_client->copy_status_to_siblings($status_code, 'user02'), [], 'returns an empty array');

    $usd_client = BOM::User::Client->new({loginid => $usd_client->loginid});
    $btc_client = BOM::User::Client->new({loginid => $btc_client->loginid});
    $eth_client = BOM::User::Client->new({loginid => $eth_client->loginid});

    ok $usd_client->status->$status_code, "USD client is set with $status_code";
    is $usd_client->status->$status_code->{staff_name}, 'user01', "USD client's status has been set with the correct staff name";
    is $usd_client->status->$status_code->{reason},     'reason', "USD client's status has been set with the correct reason";

    ok $btc_client->status->$status_code, "BTC client has been synced with $status_code";
    is $btc_client->status->$status_code->{staff_name}, 'user02', "BTC client's status has been set with the correct staff name";
    is $btc_client->status->$status_code->{reason},     'reason', "BTC client's status has been set with the correct reason";

    ok $eth_client->status->$status_code, "ETH client has been synced with $status_code";
    is $eth_client->status->$status_code->{staff_name}, 'user02', "ETH client's status has been set with the correct staff name";
    is $eth_client->status->$status_code->{reason},     'reason', "ETH client's status has been set with the correct reason";
};

subtest 'clear_status_and_sync_to_siblings' => sub {
    my $status_code = 'withdrawal_locked';

    my $user       = create_user();
    my $usd_client = create_client($user, 'USD');
    my $btc_client = create_client($user, 'BTC');

    $usd_client->status->set($status_code, 'user01', 'reason');
    $usd_client->copy_status_to_siblings($status_code, 'user01');

    my $eth_client = create_client($user, 'ETH');

    # prerequisites
    ok $usd_client->status->$status_code, "USD client has been set with $status_code";
    ok $btc_client->status->$status_code, "BTC client has been set with $status_code";
    is $eth_client->status->$status_code, undef, "ETH client is not set with status $status_code";
    # /prerequisites

    cmp_bag(
        $btc_client->clear_status_and_sync_to_siblings($status_code),
        [$usd_client->loginid, $btc_client->loginid],
        'returns an array with the loginid of the updated siblings'
    );

    cmp_bag($btc_client->clear_status_and_sync_to_siblings($status_code), [], 'returns an empty array');

    $usd_client = BOM::User::Client->new({loginid => $usd_client->loginid});
    $btc_client = BOM::User::Client->new({loginid => $btc_client->loginid});
    $eth_client = BOM::User::Client->new({loginid => $eth_client->loginid});

    is $usd_client->status->$status_code, undef, "USD client status $status_code has been cleared";
    is $btc_client->status->$status_code, undef, "BTC client status $status_code has been cleared";
    is $eth_client->status->$status_code, undef, "ETH client is not set with status $status_code";
};

subtest 'get_sibling_loginids_without_status' => sub {
    my $status_code = 'withdrawal_locked';

    my $user       = create_user();
    my $usd_client = create_client($user, 'USD');
    my $btc_client = create_client($user, 'BTC');
    my $eth_client = create_client($user, 'ETH');

    $usd_client->status->set($status_code, 'user01', 'reason');

    # prerequisites
    ok $usd_client->status->$status_code, "REQUISITE: USD client has been set with $status_code";
    is $btc_client->status->$status_code, undef, "REQUISITE: BTC client has NOT been set with $status_code";
    is $eth_client->status->$status_code, undef, "REQUISITE: ETH client has NOT been set with $status_code";
    # /prerequisites

    is ref($usd_client->get_sibling_loginids_without_status($status_code)), 'ARRAY', 'returns an array';

    cmp_bag(
        $usd_client->get_sibling_loginids_without_status($status_code),
        [$btc_client->loginid, $eth_client->loginid],
        "returns an array with the loginids of the siblings without the status $status_code"
    );

    $btc_client->status->set($status_code, 'user01', 'reason');

    cmp_bag(
        $usd_client->get_sibling_loginids_without_status($status_code),
        [$eth_client->loginid],
        "returns an array with the loginid of the only sibling that haven't set with $status_code"
    );

    $eth_client->status->set($status_code, 'user01', 'reason');

    cmp_bag($usd_client->get_sibling_loginids_without_status($status_code), [], 'returns an empty array when no sibling are found');
};

subtest 'siblings' => sub {
    my $user = create_user();
    my $usd_client = create_client($user, 'USD');

    is ref($usd_client->siblings()), 'ARRAY', 'returns an array';
    cmp_bag($usd_client->siblings(), [], 'USD client does not have siblings');

    my $btc_client = create_client($user, 'BTC');

    cmp_bag([map { $_->loginid } @{$usd_client->siblings()}], [$btc_client->loginid], 'USD client has one sibling, the BTC client');

    cmp_bag([map { $_->loginid } @{$btc_client->siblings()}], [$usd_client->loginid], 'BTC client has one sibling, the USD client');
};

subtest 'has_siblings' => sub {
    my $user = create_user();
    my $btc_client = create_client($user, 'BTC', broker_code => 'VRTC');

    ok !$btc_client->has_siblings(), 'USD client does not have siblings';

    my $usd_client = create_client($user, 'USD', broker_code => 'VRTC');

    ok $usd_client->has_siblings(), 'USD client has siblings';
    ok $btc_client->has_siblings(), 'BTC client has siblings';
};

done_testing;

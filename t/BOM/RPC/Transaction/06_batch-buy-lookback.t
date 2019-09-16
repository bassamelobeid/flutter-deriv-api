#!perl

use strict;
use warnings;

use Test::More;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use Test::BOM::RPC::Contract;
use Email::Stuffer::TestLinks;

{
    use BOM::Database::Model::AccessToken;

    # cleanup
    BOM::Database::Model::AccessToken->new->dbic->dbh->do('DELETE FROM auth.access_token');
}

my $clm = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test-manager@binary.com',
});
$clm->set_default_account('USD');    # the manager needs an account record but no money.
$clm->save;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

my $clm_token = BOM::RPC::v3::Accounts::api_token({
        client => $clm,
        args   => {
            new_token        => 'Test Token',
            new_token_scopes => ['trade'],
        },
    })->{tokens}->[0]->{token};

my $clm_token_details = BOM::RPC::v3::Utility::get_token_details($clm_token);

my @cl;
push @cl,
    BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'test-cl0@binary.com',
    });
$cl[-1]->deposit_virtual_funds;

push @cl,
    BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'test-cl1@binary.com',
    });
$cl[-1]->deposit_virtual_funds;

push @cl,
    BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'test-cl2@binary.com',
    });
# no funding here ==> error
$cl[-1]->set_default_account('USD');
$cl[-1]->save;

sub balances {
    return map { 0 + $_->default_account->balance } @_;
}

my @token;
for (@cl) {
    my $t = BOM::RPC::v3::Accounts::api_token({
            client => $_,
            args   => {
                new_token        => 'Test Token',
                new_token_scopes => ['trade'],
            },
        })->{tokens}->[0]->{token};
    push @token, $t if $t;
}

{
    my $t = BOM::RPC::v3::Accounts::api_token({
            client => $cl[0],
            args   => {
                new_token        => 'Read Token',
                new_token_scopes => ['read'],
            },
        })->{tokens}->[0]->{token};
    push @token, $t if $t;
}

is 0 + @token, 4, 'got 4 tokens';

# note explain \@token;

subtest 'trying to buy multiple lookback contracts', sub {
    my @balances = balances @cl;
    my (undef, $txn) = Test::BOM::RPC::Contract::prepare_contract(client => $clm);

    my $result = BOM::RPC::v3::Transaction::buy_contract_for_multiple_accounts {
        client              => $clm,
        token_details       => $clm_token_details,
        source              => 1,
        contract_parameters => {
            proposal      => 1,
            multiplier    => "5",
            contract_type => "LBFLOATCALL",
            currency      => "USD",
            duration      => "120",
            duration_unit => "s",
            symbol        => "R_50",
        },
        args => {
            price  => $txn->contract->ask_price,
            tokens => \@token,
        },
    };
    note explain $result;
    $result = $result->{result};

    is_deeply \@token, [map { $_->{token} } @$result], 'result is in order';

    my @differing  = (qw/contract_id transaction_id/);
    my @equal      = (qw/purchase_time buy_price start_time longcode shortcode payout/);
    my @error_keys = (qw/code message_to_client/);

    for my $k (@differing) {
        isnt $result->[0]->{$k}, undef, "got 1st $k";
        isnt $result->[1]->{$k}, undef, "got 2nd $k";
        isnt $result->[0]->{$k}, $result->[1]->{$k}, 'and they differ';
    }

    for my $k (@equal) {
        isnt $result->[0]->{$k}, undef, "got 1st $k";
        isnt $result->[1]->{$k}, undef, "got 2nd $k";
        is $result->[0]->{$k}, $result->[1]->{$k}, 'and they equal';
    }

    is $result->[2]->{code}, 'InsufficientBalance', 'token[2]: InsufficientBalance';
    is $result->[3]->{code}, 'PermissionDenied',    'token[3]: PermissionDenied';

    $balances[0] -= $result->[0]->{buy_price};
    $balances[1] -= $result->[1]->{buy_price};
    is_deeply [balances @cl], \@balances, 'client balances as expected';

    is_deeply [sort keys %{$result->[0]}], [sort 'token', @differing, @equal], 'got only expected keys for [0]';
    is_deeply [sort keys %{$result->[1]}], [sort 'token', @differing, @equal], 'got only expected keys for [1]';
    is_deeply [sort keys %{$result->[2]}], [sort 'token', @error_keys], 'got only expected keys for [2]';
    is_deeply [sort keys %{$result->[3]}], [sort 'token', @error_keys], 'got only expected keys for [3]';

    # note explain $result;
};

done_testing;

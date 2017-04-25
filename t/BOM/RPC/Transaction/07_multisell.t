#!perl

use strict;
use warnings;
use Test::MockModule;
use Test::More;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::BOM::RPC::Contract;
use BOM::Transaction;

{
    use BOM::Database::Model::AccessToken;

    # cleanup
    BOM::Database::Model::AccessToken->new->dbh->do('DELETE FROM auth.access_token');
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
    return map { 0 + $_->default_account->load->balance } @_;
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

my $contract = Test::BOM::RPC::Contract::create_contract();

my $result = BOM::RPC::v3::Transaction::buy_contract_for_multiple_accounts({
        client              => $clm,
        token_details       => $clm_token_details,
        source              => 1,
        contract_parameters => {
            proposal      => 1,
            amount        => "100",
            basis         => "payout",
            contract_type => "CALL",
            currency      => "USD",
            duration      => "120",
            duration_unit => "s",
            symbol        => "R_50",
        },
        args => {
            price  => $contract->ask_price,
            tokens => \@token,
        },
    });

$result = $result->{result};

my $buy_trx_ids = {map { $_->{transaction_id} => 1 } grep { $_->{transaction_id} } @$result};

sleep 1;
my $shortcode = $result->[0]->{shortcode};

my $mock_txn = Test::MockModule->new('BOM::Transaction');
$mock_txn->mock(_is_valid_to_sell => sub {  });

$result = BOM::RPC::v3::Transaction::sell_contract_for_multiple_accounts({
        client => $clm,
        source => 1,
        args   => {
            shortcode => $shortcode,
            price     => 0,
            tokens    => \@token,
        },
    });

$result = $result->{result};

ok(delete $buy_trx_ids->{$_->{reference_id}}) for grep { $_->{reference_id} } @$result;

ok(scalar keys %$buy_trx_ids == 0);
is($result->[2]->{code}, 'NoOpenPosition', 'contract not found code');
is($result->[2]->{message_to_client}, 'This contract was not found among your open positions.', 'contract not found code');
ok($result->[2]->{token}, 'contract not found token');
is($result->[3]->{code}, 'PermissionDenied', 'permission denied code');
ok($result->[3]->{token}, 'permission denied token');

done_testing;

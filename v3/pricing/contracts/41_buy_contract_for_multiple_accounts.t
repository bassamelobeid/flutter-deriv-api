#!perl

use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase;
use Date::Utility;

use await;

build_test_R_50_data();
my $t = build_wsapi_test();

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

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

# login
my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}{email},   $email,   'login result: email';
is $authorize->{authorize}{loginid}, $loginid, 'login result: loginid';

my ($price, $proposal_id);

my %contractParameters = (
    "amount"        => "5",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "2",
    "duration_unit" => "m",
);

sub get_proposal {

    my $proposal = $t->await::proposal({
        proposal  => 1,
        subscribe => 1,
        %contractParameters
    });
    isnt $proposal->{proposal}->{id},        undef, 'got proposal id';
    isnt $proposal->{proposal}->{ask_price}, undef, 'got ask_price';

    $proposal_id = $proposal->{proposal}->{id};
    $price       = $proposal->{proposal}->{ask_price};

    return;
}

{
    my %t;

    sub get_token {
        my @scopes = @_;
        my $cnt    = keys %t;
        my $res    = $t->await::api_token({
                api_token        => 1,
                new_token        => 'Test Token ' . $cnt,
                new_token_scopes => [@scopes]});

        for my $x (@{$res->{api_token}->{tokens}}) {
            next if exists $t{$x->{token}};
            $t{$x->{token}} = 1;
            return $x->{token};
        }
        return;
    }
}

subtest "1st try: no tokens => invalid input", sub {
    get_proposal;
    my $res = $t->await::buy_contract_for_multiple_accounts({
        buy_contract_for_multiple_accounts => $proposal_id,
        price                              => $price,
    });
    isa_ok $res->{error}, 'HASH';
    is $res->{error}->{code}, 'InputValidationFailed', 'got InputValidationFailed';
};

subtest "2nd try: dummy tokens => success", sub {
    my $res = $t->await::buy_contract_for_multiple_accounts({
        buy_contract_for_multiple_accounts => $proposal_id,
        price                              => $price,
        tokens                             => ['DUMMY0', 'DUMMY1'],
    });
    isa_ok $res->{buy_contract_for_multiple_accounts}, 'HASH';

    is_deeply $res->{buy_contract_for_multiple_accounts},
        {
        'result' => [{
                'code'              => 'InvalidToken',
                'message_to_client' => 'Invalid token',
                'token'             => 'DUMMY0'
            },
            {
                'code'              => 'InvalidToken',
                'message_to_client' => 'Invalid token',
                'token'             => 'DUMMY1'
            }
        ],
        },
        'got expected result';

    test_schema('buy_contract_for_multiple_accounts', $res);

    my $forget = $t->await::forget({forget => $proposal_id});
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';
};

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch + 2,
    quote      => '963'
});

my $tokens_for_sell    = [];
my $trx_ids            = {};
my $shortcode_for_sell = undef;
subtest "3rd try: the real thing => success", sub {
    # Here we trust that the function in bom-rpc works correctly. We
    # are not going to test all possible variations. In particular,
    # all the tokens used belong to the same account.
    my @tokens = map { get_token 'trade' } (1, 2);
    push @tokens, get_token 'read';    # generates an error
    push @tokens, $token;              # add the login token as well
    get_proposal;
    my $res = $t->await::buy_contract_for_multiple_accounts({
        buy_contract_for_multiple_accounts => $proposal_id,
        price                              => $price,
        tokens                             => \@tokens,
    });

    isa_ok $res->{buy_contract_for_multiple_accounts}, 'HASH';

    test_schema('buy_contract_for_multiple_accounts', $res);

    $tokens_for_sell    = [map { $_->{token} } grep { $_->{shortcode} } @{$res->{buy_contract_for_multiple_accounts}{result}}];
    $shortcode_for_sell = [map { $_->{shortcode} } grep { $_->{shortcode} } @{$res->{buy_contract_for_multiple_accounts}{result}}]->[0];

    my $forget = $t->await::forget({forget => $proposal_id});
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';

    # checking statement
    my $stmt = $t->await::statement({
        statement => 1,
        limit     => 3
    });

    $trx_ids = +{map { $_->{transaction_id} => 1 } @{$stmt->{statement}->{transactions}}};

    is_deeply([
            sort { $a->[0] <=> $b->[0] }
            map  { [$_->{contract_id}, $_->{transaction_id}, -$_->{amount}] } @{$stmt->{statement}->{transactions}}
        ],
        [
            sort    { $a->[0] <=> $b->[0] }
                map { $_->{code} ? () : [$_->{contract_id}, $_->{transaction_id}, $_->{buy_price}] }
                @{$res->{buy_contract_for_multiple_accounts}->{result}}
        ],
        'got all 3 contracts via statement call'
    );
};
### If we'll be sell it immediately we'll fail basic_validation
sleep 1;

subtest "try to sell: dummy tokens => success", sub {
    my $res = $t->await::sell_contract_for_multiple_accounts({
        sell_contract_for_multiple_accounts => 1,
        shortcode                           => $shortcode_for_sell,
        price                               => 2.42,
        tokens                              => ['DUMMY0', 'DUMMY1'],
    });
    isa_ok $res->{sell_contract_for_multiple_accounts}, 'HASH';
    isa_ok $res->{sell_contract_for_multiple_accounts}{result}, 'ARRAY';
    isa_ok $res->{sell_contract_for_multiple_accounts}{result}->[0], 'HASH';

    is_deeply $res->{sell_contract_for_multiple_accounts}{result},
        [{
            'code'              => 'InvalidToken',
            'message_to_client' => 'Invalid token',
            'token'             => 'DUMMY0'
        },
        {
            'code'              => 'InvalidToken',
            'message_to_client' => 'Invalid token',
            'token'             => 'DUMMY1'
        }
        ],
        'got expected result';

    test_schema('sell_contract_for_multiple_accounts', $res);
};

subtest "sell_contract_for_multiple_accounts => successful", sub {
    $res = $t->await::sell_contract_for_multiple_accounts({
        sell_contract_for_multiple_accounts => 1,
        shortcode                           => $shortcode_for_sell,
        price                               => 2.42,
        tokens                              => $tokens_for_sell,
    });
    isa_ok $res->{sell_contract_for_multiple_accounts}{result}, 'ARRAY';
    isa_ok $res->{sell_contract_for_multiple_accounts}{result}->[0], 'HASH';
    ok scalar @{$res->{sell_contract_for_multiple_accounts}{result}} == 3, 'check res count';
    ok(defined $res->{sell_contract_for_multiple_accounts}{result}->[0]->{transaction_id}, "check trx exist");
    ok(defined $res->{sell_contract_for_multiple_accounts}{result}->[0]->{reference_id},   "check ref exist");
    for my $r (@{$res->{sell_contract_for_multiple_accounts}{result}}) {
        ok(defined $r->{reference_id} && defined $trx_ids->{$r->{reference_id}}, "Check transaction ID");
    }
    test_schema('sell_contract_for_multiple_accounts', $res);
};

subtest "invalid durations", sub {

    $contractParameters{duration} = 100000000;
    $res = $t->await::buy_contract_for_multiple_accounts({
        buy_contract_for_multiple_accounts => 1,
        price                              => 0,
        tokens                             => \@tokens,
        parameters                         => \%contractParameters
    });
    is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with huge duration';

    $contractParameters{duration} = -1;
    $res = $t->await::buy_contract_for_multiple_accounts({
        buy_contract_for_multiple_accounts => 1,
        price                              => 0,
        tokens                             => \@tokens,
        parameters                         => \%contractParameters
    });
    is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with negative duration';

};

$t->finish_ok;

done_testing();

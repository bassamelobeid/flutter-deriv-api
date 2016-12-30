#!perl

use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Platform::Runtime;

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
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

# login
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email,   'login result: email';
is $authorize->{authorize}->{loginid}, $loginid, 'login result: loginid';

my ($price, $proposal_id);

sub get_proposal {
    #BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');

    my %contractParameters = (
        "amount"        => "5",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m",
    );
    $t = $t->send_ok({
            json => {
                "proposal"  => 1,
                "subscribe" => 1,
                %contractParameters
            }});
    $t->message_ok;
    my $proposal = decode_json($t->message->[1]);
    isnt $proposal->{proposal}->{id},        undef, 'got proposal id';
    isnt $proposal->{proposal}->{ask_price}, undef, 'got ask_price';

    $proposal_id = $proposal->{proposal}->{id};
    $price       = $proposal->{proposal}->{ask_price};

    return;
}

sub filter_proposal {
    ## skip proposal
    my $res;
    for (my $i = 0; $i < 100; $i++) {    # prevent infinite loop
        $t   = $t->message_ok;
        $res = decode_json($t->message->[1]);
        # note explain $res;
        return $res unless $res->{msg_type} eq 'proposal';
        $proposal    = decode_json($t->message->[1]);
        $proposal_id = $proposal->{proposal}->{id};
        $price       = $proposal->{proposal}->{ask_price} || 0;
    }
    return $res;
}

{
    my %t;

    sub get_token {
        my @scopes = @_;
        my $cnt    = keys %t;
        $t = $t->send_ok({
                json => {
                    api_token        => 1,
                    new_token        => 'Test Token ' . $cnt,
                    new_token_scopes => [@scopes]}})->message_ok;
        my $res = decode_json($t->message->[1]);
        # note explain $res;
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
    $t = $t->send_ok({
            json => {
                buy_contract_for_multiple_accounts => $proposal_id,
                price                              => $price,
            }});
    my $res = filter_proposal;
    isa_ok $res->{error}, 'HASH';
    is $res->{error}->{code}, 'InputValidationFailed', 'got InputValidationFailed';
};

subtest "2nd try: dummy tokens => success", sub {
    $t = $t->send_ok({
            json => {
                buy_contract_for_multiple_accounts => $proposal_id,
                price                              => $price,
                tokens                             => ['DUMMY0', 'DUMMY1'],
            }});
    my $res = filter_proposal;
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

    $t = $t->send_ok({json => {forget => $proposal_id}})->message_ok;
    my $forget = decode_json($t->message->[1]);
    # note explain $forget;
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';
};

subtest "3rd try: the real thing => success", sub {
    # Here we trust that the function in bom-rpc works correctly. We
    # are not going to test all possible variations. In particular,
    # all the tokens used belong to the same account.
    my @tokens = map { get_token 'trade' } (1, 2);
    push @tokens, get_token 'read';    # generates an error
    push @tokens, $token;              # add the login token as well
                                       # note explain \@tokens;
    get_proposal;
    $t = $t->send_ok({
            json => {
                buy_contract_for_multiple_accounts => $proposal_id,
                price                              => $price,
                tokens                             => \@tokens,
            }});
    my $res = filter_proposal;
    isa_ok $res->{buy_contract_for_multiple_accounts}, 'HASH';

    # note explain $res;
    test_schema('buy_contract_for_multiple_accounts', $res);

    $t = $t->send_ok({json => {forget => $proposal_id}})->message_ok;
    my $forget = decode_json($t->message->[1]);
    # note explain $forget;
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';

    # checking statement
    $t = $t->send_ok({
            json => {
                statement => 1,
                limit     => 3
            }});
    my $stmt = filter_proposal;
    # note explain $stmt;

    is_deeply([
            sort { $a->[0] <=> $b->[0] }
            map { [$_->{contract_id}, $_->{transaction_id}, -$_->{amount}] } @{$stmt->{statement}->{transactions}}
        ],
        [
            sort { $a->[0] <=> $b->[0] }
                map { $_->{code} ? () : [$_->{contract_id}, $_->{transaction_id}, $_->{buy_price}] }
                @{$res->{buy_contract_for_multiple_accounts}->{result}}
        ],
        'got all 3 contracts via statement call'
    );
};

$t->finish_ok;

done_testing();

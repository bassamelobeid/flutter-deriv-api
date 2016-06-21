#!perl

use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Platform::SessionCookie;
use BOM::System::RedisReplicated;

# cleanup
use BOM::Database::Model::AccessToken;
BOM::Database::Model::AccessToken->new->dbh->do("
    DELETE FROM $_
") foreach ('auth.access_token');


build_test_R_50_data();
my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'sy@regentmarkets.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

# login
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com', 'login result: email';
is $authorize->{authorize}->{loginid}, 'CR2002', 'login result: loginid';

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
    isnt $proposal->{proposal}->{id}, undef, 'got proposal id';
    isnt $proposal->{proposal}->{ask_price}, undef, 'got ask_price';

    $proposal_id = $proposal->{proposal}->{id};
    $price       = $proposal->{proposal}->{ask_price};

    return;
}

sub filter_proposal {
    ## skip proposal
    my $res;
    for (my $i=0; $i<100; $i++) {   # prevent infinite loop
        $t = $t->message_ok;
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
        my $cnt = keys %t;
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

    is_deeply $res->{buy_contract_for_multiple_accounts}, {
        'result' => [
            {
                'code' => 'InvalidToken',
                'message_to_client' => 'Invalid token',
                'token' => 'DUMMY0'
            },
            {
                'code' => 'InvalidToken',
                'message_to_client' => 'Invalid token',
                'token' => 'DUMMY1'
            }
        ],
    }, 'got expected result';

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
    my @tokens = map { get_token 'trade' } (1,2);
    push @tokens, get_token 'read'; # generates an error
    push @tokens, $token;           # add the login token as well
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

    is_deeply ([sort {$a->[0] <=> $b->[0]}
                map {[$_->{contract_id}, $_->{transaction_id}, -$_->{amount}]}
                @{$stmt->{statement}->{transactions}}],
               [sort {$a->[0] <=> $b->[0]}
                map {$_->{code} ? () : [$_->{contract_id}, $_->{transaction_id}, $_->{buy_price}]}
                @{$res->{buy_contract_for_multiple_accounts}->{result}}],
               'got all 3 contracts via statement call');
};

$t->finish_ok;

done_testing();

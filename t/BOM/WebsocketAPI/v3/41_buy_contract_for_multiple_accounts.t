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
        note explain $res;
        return $res unless $res->{msg_type} eq 'proposal';
        $proposal    = decode_json($t->message->[1]);
        $proposal_id = $proposal->{proposal}->{id};
        $price       = $proposal->{proposal}->{ask_price} || 0;
    }
    return $res;
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

    $t = $t->send_ok({json => {forget => $proposal_id}})->message_ok;
    my $forget = decode_json($t->message->[1]);
    note explain $forget;
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';
};

subtest "3rd try: the real thing => success", sub {
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

    $t = $t->send_ok({json => {forget => $proposal_id}})->message_ok;
    my $forget = decode_json($t->message->[1]);
    note explain $forget;
    is $forget->{forget}, 0, 'buying a proposal deletes the stream';
};

$t->finish_ok;

done_testing();



__END__

my $rpc_caller = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
my $call_params;
$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({
        json => {
            get_corporate_actions => 1,
            symbol                => "FPFP",
            start                 => "2013-03-27",
            end                   => "2013-03-30",
        }})->message_ok;
ok !$call_params->{token};
$rpc_caller->unmock_all;

$t = $t->send_ok({
        json => {
            get_corporate_actions => 1,
            symbol                => "FPFP",
            start                 => "2013-03-27",
            end                   => "2013-03-30",
        }})->message_ok;
my $corporate_actions = decode_json($t->message->[1]);
is $corporate_actions->{msg_type}, 'get_corporate_actions';

$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
is $call_params->{token}, $token;
$rpc_caller->unmock_all;

$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
my $portfolio = decode_json($t->message->[1]);
is $portfolio->{msg_type}, 'portfolio';
ok $portfolio->{portfolio}->{contracts};
ok $portfolio->{portfolio}->{contracts}->[0]->{contract_id};
test_schema('portfolio', $portfolio);

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            contract_id            => $portfolio->{portfolio}->{contracts}->[0]->{contract_id},
        }});
$t = $t->message_ok;
my $res = decode_json($t->message->[1]);

if (exists $res->{proposal_open_contract}) {
    ok $res->{proposal_open_contract}->{contract_id};
    test_schema('proposal_open_contract', $res);
}

sleep 1;
$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({
        json => {
            buy        => 1,
            price      => $ask_price || 0,
            parameters => \%contractParameters,
        },
    })->message_ok;
is $call_params->{token}, $token;
ok $call_params->{contract_parameters};
$rpc_caller->unmock_all;

$t = $t->send_ok({
        json => {
            buy        => 1,
            price      => $ask_price || 0,
            parameters => \%contractParameters,
        },
    });

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    # note explain $res;
    is $res->{msg_type}, 'buy';
    ok $res->{buy};
    ok $res->{buy}->{contract_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({
        json => {
            sell       => 1,
            price      => $ask_price || 0,
            parameters => \%contractParameters,
        },
    })->message_ok;
is $call_params->{token}, $token;
$rpc_caller->unmock_all;

$t->finish_ok;

done_testing();

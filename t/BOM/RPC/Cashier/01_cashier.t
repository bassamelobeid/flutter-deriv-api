use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Email::Address::UseXS;
use BOM::User;

use BOM::Test::Email qw(:no_event);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::Client;
use LWP::UserAgent;
require Test::NoWarnings;

# this must be declared at the end, otherwise BOM::Test::Email will fail
use Test::Most;

my $mocked_call = Test::MockModule->new('LWP::UserAgent');

my ($t, $rpc_ct);
subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $method         = 'cashier';
my $email          = 'dummy' . rand(999) . '@binary.com';
my $user_client_cr = BOM::User->create(
    email          => 'cr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
});
$client_cr->set_default_account('USD');

$user_client_cr->add_client($client_cr);

subtest 'Doughflow' => sub {
    my $params = {};
    $params->{args}->{cashier} = 'deposit';
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token123');
    $params->{domain} = 'binary.com';

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_internal_message_like(qr/frontend not found/, 'No frontend error');

    $mocked_call->mock('post', sub { return {_content => 'customer too old'} });

    mailbox_clear();

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_internal_message_like(qr/customer too old/, 'Customer too old error')
        ->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    my $msg = mailbox_search(subject => qr/DOUGHFLOW_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/over 110 years old/, "Correct message to too old";

    $mocked_call->mock('post', sub { return {_content => 'customer underage'} });

    mailbox_clear();

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_internal_message_like(qr/customer underage/, 'Customer underage error')
        ->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    $msg = mailbox_search(subject => qr/DOUGHFLOW_MIN_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/under 18 years/, "Correct message to underage";

    $mocked_call->mock('post', sub { return {_content => 'abcdef'} });

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_internal_message_like(qr/abcdef/, 'Unknown Doughflow error')
        ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.', 'Correct Unknown Doughflow error message');

};

subtest 'validate_amount' => sub {

    my $mocked_fun = Test::MockModule->new('Format::Util::Numbers');
    $mocked_fun->mock('get_precision_config', sub { return {amount => {'BBB' => 5}} });
    is(BOM::RPC::v3::Cashier::validate_amount(0.00001, 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1e-05,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('1e-05', 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('fred',  'BBB'), 'Invalid amount.', 'Invalid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(0.001,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1,       'BBB'), undef,             'Valid Amount');
    is(
        BOM::RPC::v3::Cashier::validate_amount(0.000001, 'BBB'),
        'Invalid amount. Amount provided can not have more than 5 decimal places.',
        'Too many decimals'
    );
};

done_testing();


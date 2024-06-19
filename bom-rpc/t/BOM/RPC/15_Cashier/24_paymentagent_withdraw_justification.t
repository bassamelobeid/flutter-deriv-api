use strict;
use warnings;
use Test::More;
use Test::Deep;
use BOM::Config::Redis;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email;
use Brands;

my $client       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $rpc_ct       = BOM::Test::RPC::QueueClient->new();
my $justfication = 'I like payment agents';
my $brand        = Brands->new(name => 'deriv');
my $redis        = BOM::Config::Redis::redis_replicated_write();

my $params = {
    token => BOM::Platform::Token::API->new->create_token($client->loginid, 'test'),
    brand => 'deriv',
    args  => {
        paymentagent_withdraw_justification => 1,
        message                             => $justfication,
    }};

my $result = $rpc_ct->call_ok('paymentagent_withdraw_justification', $params)->has_no_system_error->has_no_error->result;
is $result, 1, 'success result is 1';

my $msg = mailbox_search(body => qr/$justfication/);
cmp_deeply(
    $msg,
    {
        body    => $justfication,
        subject => re('^Payment agent withdraw justification submitted by ' . $client->loginid . ' at \w+'),
        from    => $brand->emails('system'),
        to      => [$brand->emails('payments')],
    },
    'expected email sent to payments team'
);

$rpc_ct->call_ok('paymentagent_withdraw_justification', $params)
    ->has_no_system_error->has_error->error_code_is('JustificationAlreadySubmitted', 'error code for repeat submission')
    ->error_message_is('You cannot submit another payment agent withdrawal justification within 24 hours.', 'error mssage for repeat submission');

my $key = 'PA_WITHDRAW_JUSTIFICATION_SUBMIT::' . $client->loginid;
cmp_ok $redis->ttl($key), '<=', 86400, 'redis key is set with 24 hour expiry';
$redis->del($key);

$rpc_ct->call_ok('paymentagent_withdraw_justification', $params)->has_no_system_error->has_no_error('can submit again after key expires');

done_testing;

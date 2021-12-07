use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper qw(deposit_validate);
use JSON::MaybeUTF8 qw(:v1);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

BOM::User->create(
    email    => $client->email,
    password => 'x'
)->add_client($client);

my $mock_mapper = Test::MockModule->new('BOM::Database::DataMapper::Payment::DoughFlow');
my $methods     = [];
$mock_mapper->mock(get_doughflow_methods => sub { $methods });

my $r = deposit_validate(
    loginid           => $client->loginid,
    payment_processor => 'megaPay',
);
my $resp = decode_json_utf8($r->content);

cmp_deeply $resp, {allowed => 1}, 'new client is allowed';

$methods = [{deposit_poi_required => 1}];

$r = deposit_validate(
    loginid           => $client->loginid,
    payment_processor => 'megaPay',
);
$resp = decode_json_utf8($r->content);

is $resp->{allowed},   '0',                      'not allowed if method requires POI';
like $resp->{message}, qr/verify your identity/, 'correct response message';
is $client->status->allow_document_upload->{reason}, 'Deposit attempted with method requiring POI (megaPay)',
    'allow_document_upload status added with correct reason';

$client->status->set('age_verification', 'system', 'x');

$r = deposit_validate(
    loginid           => $client->loginid,
    payment_processor => 'megaPay',
);
$resp = decode_json_utf8($r->content);
cmp_deeply $resp, {allowed => 1}, 'client is allowed with age_verification';

done_testing();

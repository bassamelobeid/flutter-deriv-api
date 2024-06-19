use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper                                  qw(deposit_validate);
use JSON::MaybeUTF8                            qw(:v1);

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

is $resp->{allowed}, '0', 'not allowed if method requires POI';
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

subtest 'df deposit requires POI' => sub {
    my $cumulative_totals = {};
    my $df_mock           = Test::MockModule->new('BOM::Database::DataMapper::Payment::DoughFlow');
    $df_mock->mock(
        'payment_type_cumulative_total',
        sub {
            my (undef, $args) = @_;

            my $payment_type = $args->{payment_type} || return 0;

            return $cumulative_totals->{$payment_type} // 0;
        });

    $methods = [{deposit_poi_required => 0}];
    $client->status->clear_age_verification;

    $client->status->clear_df_deposit_requires_poi;
    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
        payment_type      => 'CreditCard',
    );

    $resp = decode_json_utf8($r->content);
    ok $resp->{allowed}, 'Allowed to deposit via DF (no df_deposit_requires_poi status)';

    $client->status->set('df_deposit_requires_poi', 'system', 'x');
    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
    );
    $resp = decode_json_utf8($r->content);
    ok $resp->{allowed}, 'Allowed to deposit via DF (no payment type)';

    $client->residence('za');
    $client->save();
    $cumulative_totals->{CreditCard} = 100;
    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
        payment_type      => 'CreditCard',
    );
    $resp = decode_json_utf8($r->content);
    ok $resp->{allowed}, 'Allowed to deposit via DF (limit not crossed)';

    $client->residence('br');
    $client->save();
    $cumulative_totals->{CreditCard} = 500;
    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
        payment_type      => 'CreditCard',
    );
    $resp = decode_json_utf8($r->content);
    ok $resp->{allowed}, 'Allowed to deposit via DF (residence=br)';

    $client->residence('za');
    $client->save();
    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
        payment_type      => 'CreditCard',
    );
    $resp = decode_json_utf8($r->content);
    is $resp->{allowed}, '0', 'not allowed if the client is flagged';
    like $resp->{message}, qr/You\'ve hit the deposit limit, we\'ll need to verify your identity/, 'correct response message';

    $r = deposit_validate(
        loginid           => $client->loginid,
        payment_processor => 'dogePay',
        payment_type      => 'DogeVault',
    );
    $resp = decode_json_utf8($r->content);
    ok $resp->{allowed}, 'Allowed to deposit via DF';

    $df_mock->unmock_all;
};

done_testing();

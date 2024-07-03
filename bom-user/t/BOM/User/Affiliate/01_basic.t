use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Affiliate;

subtest 'initial methods' => sub {
    my $client;

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CRA',
            email       => 'affiliate@deriv.com',
        });
    }
    'CRA client can be created';

    ok $client->loginid =~ /^CRA[0-9]+$/, 'Expected broker code';

    isa_ok $client, 'BOM::User::Affiliate', 'from create_client()';

    ok $client->is_affiliate, 'is_affiliate true';
    ok !$client->is_wallet,   'is_wallet false';
    ok !$client->can_trade,   'can_trade false';

    my $affiliate;
    lives_ok {
        $affiliate = $client->get_client_instance($client->loginid);
    }
    'CRA client can be retrieved';

    isa_ok $affiliate, 'BOM::User::Affiliate', 'from get_client_instance()';
    ok $affiliate->is_affiliate, 'is_affiliate true';
    ok !$affiliate->is_wallet,   'is_wallet false';
    ok !$affiliate->can_trade,   'can_trade false';
    is $affiliate->landing_company->short, 'dsl', 'Expected landing company';
};

subtest 'create from user' => sub {
    my $user = BOM::User->create(
        email    => 'someaff@binary.com',
        password => 'aff1234',
    );

    my $aff = $user->create_affiliate(
        broker_code              => 'CRA',
        email                    => 'afftest@binary.com',
        client_password          => 'okcomputer',
        residence                => 'br',
        first_name               => 'test',
        last_name                => 'asdf',
        address_line_1           => 'super st',
        address_city             => 'sao paulo',
        phone                    => '+381902941243',
        secret_question          => 'Mother\'s maiden name',
        secret_answer            => 'the iron maiden',
        account_opening_reason   => 'Hedging',
        non_pep_declaration_time => Date::Utility->new()->_plus_years(1)->date_yyyymmdd,
    );

    isa_ok $aff, 'BOM::User::Affiliate', 'Got the expected instance';
};

subtest 'user create with dynamic works SIDC' => sub {
    my $user;
    lives_ok {
        $user = BOM::User->create(
            email    => 'test@tst.com',
            password => '123456',
        )
    }
    'User created';

    my $affiliate_details = {
        partner_token => 'ExampleSIDCDW',
        provider      => 'dynamicworks'
    };

    my $result = $user->set_affiliated_client_details($affiliate_details);

    ok $result, 'set_affiliated_client_details() returns true, details stored successfully';

    $result = $user->get_affiliated_client_details();

    is($result->{partner_token},    'ExampleSIDCDW', 'get_affiliated_client_details() returns correct details');
    is($result->{provider},         'dynamicworks',  'Provider is correct and stored  level');
    is($result->{user_external_id}, undef,           'Client DW ID is undef');

    $result = $user->update_affiliated_client_details({partner_token => 'New token', client_id => 'example client id'});

    ok $result, 'update_affiliated_client_details() returns true, details updated successfully';

    $result = $user->get_affiliated_client_details();

    is($result->{partner_token},    'New token',         'get_affiliated_client_details() returns correct details');
    is($result->{user_external_id}, 'example client id', 'get_affiliated_client_details() returns correct updated details');
};

done_testing;

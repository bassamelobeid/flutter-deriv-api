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

done_testing;

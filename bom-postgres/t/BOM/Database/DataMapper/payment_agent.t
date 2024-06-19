use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Database::DataMapper::PaymentAgent;

subtest 'get_payment_agents_details_full' => sub {
    my $email     = 'JoeSmith@binary.com';
    my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $pa_client->email('pa+1' . $email);
    $pa_client->set_default_account('USD');
    $pa_client->save;
    my $user = BOM::User->create(
        email    => $pa_client->email,
        password => 'test',
    );
    $user->add_client($pa_client);

    # make him a payment agent
    my $object_pa = $pa_client->payment_agent({
        payment_agent_name    => 'Joe',
        email                 => 'pa+1' . $email,
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $pa_client->save;
    my $pa = $pa_client->get_payment_agent;
    $pa->set_countries(['id', 'pk']);
    my %test_inked_data = (
        urls                      => [{url            => 'https://wwww.pa.com'}, {url            => 'https://wwww.nowhere.com'}],
        phone_numbers             => [{phone_number   => '+12345678'},           {phone_number   => '+87654321'}],
        supported_payment_methods => [{payment_method => 'MasterCard'},          {payment_method => 'Visa'}],
    );
    $pa->$_($test_inked_data{$_}) for keys %test_inked_data;
    $pa->save;

    # Add new payment agent with is_listed = false and different country
    my $pa_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $pa_client_2->email('pa+2' . $email);
    $pa_client_2->set_default_account('USD');
    $pa_client_2->save;
    $user->add_client($pa_client_2);

    # make him a payment agent
    my $object_pa2 = $pa_client_2->payment_agent({
        payment_agent_name    => 'Joe 2',
        email                 => 'pa+2' . $email,
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 'f',
    });
    $pa_client_2->save;

    my $pa_2 = $pa_client_2->get_payment_agent;
    $pa_2->set_countries(['id', 'pk']);

    my $mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => 'CR'});

    subtest 'No arguements' => sub {
        ok exception { $mapper->get_payment_agents_details_full() }, 'exception thrown when no arguments passed';
    };

    subtest 'query with linked details' => sub {
        my $payment_agent = $mapper->get_payment_agents_details_full(
            country_code => 'id',
            currency     => 'USD',
            is_listed    => 't',
        );
        ok($payment_agent->{$pa->client_loginid},                                'payment agent exists');
        ok($payment_agent->{$pa->client_loginid}->{payment_agent_name} eq 'Joe', 'name is correct');
        for my $field (keys %test_inked_data) {
            my @data;
            push @data, (values $_->%*) for ($pa->$field->@*);
            cmp_deeply $payment_agent->{$pa->client_loginid}->{$field}, bag(@data), "$field is correctly retrieved";
        }
    };
    subtest 'query with linked details' => sub {
        my $payment_agent = $mapper->get_payment_agents_details_full(
            country_code => 'id',
            currency     => 'USD',
            is_listed    => 't',
        );
        ok($payment_agent->{$pa->client_loginid},                                'payment agent exists');
        ok($payment_agent->{$pa->client_loginid}->{payment_agent_name} eq 'Joe', 'name is correct');
        for my $field (keys %test_inked_data) {
            my @data;
            push @data, (values $_->%*) for ($pa->$field->@*);
            cmp_deeply $payment_agent->{$pa->client_loginid}->{$field}, bag(@data), "$field is correctly retrieved";
        }
    };
    subtest 'query with mapped linked details' => sub {
        my $payment_agent = $mapper->get_payment_agents_details_full(
            country_code         => 'id',
            currency             => 'USD',
            is_listed            => 't',
            details_field_mapper => {
                urls                      => 'url',
                phone_numbers             => 'phone_number',
                supported_payment_methods => 'payment_method',
            });
        ok($payment_agent->{$pa->client_loginid}, 'payment agent exists');
        is($payment_agent->{$pa->client_loginid}->{payment_agent_name}, 'Joe', 'name is correct');
        for my $field (keys %test_inked_data) {
            cmp_deeply $payment_agent->{$pa->client_loginid}->{$field}, bag($pa->$field->@*), "$field is correctly retrieved";
        }
    };
    subtest 'not listed no linked details' => sub {
        my $payment_agent = $mapper->get_payment_agents_details_full(
            country_code => 'id',
            broker_code  => 'CR',
            currency     => 'USD',
            is_listed    => 'f',
        );
        is($payment_agent->{$pa->client_loginid}, undef, 'agent not returned when is_listed is false');
        ok($payment_agent->{$pa_2->client_loginid}, 'not listed agent returned when is_listed is false');

    };
    subtest 'no linked info' => sub {
        my $payment_agent = $mapper->get_payment_agents_details_full(
            country_code => 'id',
            broker_code  => 'CR',
            currency     => 'USD',
            is_listed    => 'f',
        );
        for my $field (keys %test_inked_data) {
            is($payment_agent->{$field}, undef, "$field is not returned when it's not set");
        }
    }
};

subtest 'map_linked_details' => sub {
    my $mapper  = BOM::Database::DataMapper::PaymentAgent->new({broker_code => 'CR'});
    my $db_rows = [{
            urls                      => ['http://www.MyPAMyAdventure.com/', 'http://www.MyPAMyAdventure2.com/'],
            phone_numbers             => ['+12345678',                       '+87654321'],
            supported_payment_methods => ['MasterCard',                      'Visa'],
        }];
    my $details_field_mapper = {
        urls                      => 'url',
        phone_numbers             => 'phone_number',
        supported_payment_methods => 'payment_method',
    };
    my $expected_result = [{
            urls                      => [{url          => 'http://www.MyPAMyAdventure.com/'}, {url          => 'http://www.MyPAMyAdventure2.com/'}],
            phone_numbers             => [{phone_number => '+12345678'},                       {phone_number => '+87654321'}],
            supported_payment_methods => [{payment_method => 'MasterCard'},                    {payment_method => 'Visa'}],
        }];

    $mapper->map_linked_details($db_rows, $details_field_mapper);

    cmp_deeply $db_rows, $expected_result, 'linked details are mapped correctly';
};

done_testing();

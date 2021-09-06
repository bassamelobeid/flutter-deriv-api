use strict;
use warnings;
use BOM::User;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use Data::Dumper;
use BOM::Config::Runtime;
use BOM::RPC::v3::Accounts;

subtest 'test _find_updated_fields sub' => sub {
    my $email = 'dummy@binary.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'test'
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    # Test
    $client->email($email);
    $client->save;
    $user->add_client($client);

    # default args
    my $args = {
        account_opening_reason    => 'account_opening_reason value',
        address_city              => 'address_city value',
        address_line_1            => 'address_line_1 value',
        address_line_2            => 'address_line_2 value',
        address_postcode          => 'address_postcode value',
        address_state             => 'address_state value',
        allow_copiers             => 'allow_copiers value',
        citizen                   => 'citizen value',
        date_of_birth             => 'date_of_birth value',
        first_name                => 'first_name value',
        last_name                 => 'last_name value',
        phone                     => 'phone value',
        place_of_birth            => 'place_of_birth value',
        residence                 => 'residence value',
        salutation                => 'salutation value',
        secret_answer             => 'secret_answer value',
        secret_question           => 'secret_question value',
        tax_identification_number => 'tax_identification_number value',
        tax_residence             => 'tax_residence value',
    };

    my $updated_fields;

    $updated_fields = BOM::RPC::v3::Accounts::_find_updated_fields({
        client => $client,
        args   => $args
    });

    # All fields are different
    is_deeply $args, $updated_fields, 'All the fields are exist and different from client properties.';

    $args->{email_consent} = 0;
    $updated_fields = BOM::RPC::v3::Accounts::_find_updated_fields({
        client => $client,
        args   => $args
    });
    delete $args->{email_consent};
    is_deeply $updated_fields, $args,
        'If $args->{email_consent} is not different from $user->email_consent it should not appears in $updated_fields.';

    $args->{email_consent} = 1;
    $updated_fields = BOM::RPC::v3::Accounts::_find_updated_fields({
        client => $client,
        args   => $args
    });
    is_deeply $updated_fields, $args, 'If $arg->email_consent exists and be different from $user->email_consent it appears in updated fields list.';
};

done_testing();

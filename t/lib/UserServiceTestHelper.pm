package UserServiceTestHelper;

use strict;
use warnings;
use BOM::User;
use BOM::User::Client;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use Date::Utility;
use UUID::Tiny;

our @app_ids = ();

sub create_context {
    my $user = shift;
    return {
        'correlation_id' => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
        'auth_token'     => 'Test Token, just for testing',
    };
}

sub create_user {
    my $email = shift;

    my $user = BOM::User->create(
        email          => $email,
        password       => "something something darkside...",
        email_verified => 1,
        email_consent  => 1,
    );

    # Attach a bunch of clients to the user, only one of which is enabled and has real data
    my %clients =
        map {
        $_ => BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                email                    => 'bad@realbad.bad',                 # User has real email, should NEVER see this
                client_password          => 'badbadbad',                       # User has real password, should NEVER see this
                broker_code              => $_ eq 'virtual' ? 'VRTC' : 'CR',
                broker_code              => 'CR',
                residence                => $_ eq 'enabled' ? 'aq'                                 : 'no',
                first_name               => $_ eq 'enabled' ? 'Frieren'                            : 'Bad',
                last_name                => $_ eq 'enabled' ? 'Elf'                                : 'Bad',
                address_line_1           => $_ eq 'enabled' ? '456 Ancient Heroes Lane'            : 'Bad',
                address_line_1           => $_ eq 'enabled' ? 'Sage\'s Rest, Eternal Highlands'    : 'Bad',
                address_city             => $_ eq 'enabled' ? 'Afterlife\'s Gate, The Great North' : 'Bad',
                phone                    => $_ eq 'enabled' ? '+44123456789'                       : 'Bad',
                secret_question          => $_ eq 'enabled' ? '42'                                 : 'Bad',
                secret_answer            => $_ eq 'enabled' ? 'What was the question?'             : 'Bad',
                account_opening_reason   => $_ eq 'enabled' ? 'Fern made me do it'                 : 'Bad',
                non_pep_declaration_time => Date::Utility->new()->_plus_years(1)->date_yyyymmdd,
                date_of_birth            => $_ eq 'enabled' ? '1984-01-01' : '2000-01-01',
                fatca_declaration        => undef,
            })
        } qw( disabled self_closed enabled );

    $user->add_client($clients{$_}) for keys %clients;

    $clients{disabled}->status->set('disabled', 'system', 'test');
    $clients{self_closed}->status->set('closed',   'system', 'test');
    $clients{self_closed}->status->set('disabled', 'system', 'test');

    # Now add some tokens
    my $oauth = BOM::Database::Model::OAuth->new;
    if (scalar(@app_ids) == 0) {
        for (0 .. 2) {
            my $app = $oauth->create_app({
                name         => "Test App$_",
                user_id      => $user->id,
                scopes       => ['read', 'trade', 'admin'],
                redirect_uri => "https://www.example$_.com/"
            });
            push @app_ids, $app->{app_id};
        }
    }

    $oauth->store_access_token_only(1, $clients{enabled}->loginid);

    foreach (@app_ids) {
        $oauth->generate_refresh_token($user->id, $_, 29, 60 * 60 * 24);
    }

    # Fake a login history
    my $error         = 0;
    my $environment   = 'test', my $app_id = 12345;
    my $log_as_failed = 0;

    # 3 backoffice, 2 normal
    for my $i (0 .. 4) {
        $app_id = ($i % 2) == 0 ? 4 : 12345;
        $user->dbic->run(
            fixup => sub {
                $_->do('select users.record_login_history(?,?,?,?,?)', undef, $user->{id}, $error ? 'f' : 't', $log_as_failed, $environment, $app_id);
            });
    }

    return $user;
}

1;

package BOM::RPC::v3::App;

use 5.014;
use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::OAuth;

sub register {
    my $params = shift;

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $args         = $params->{args};
    my $name         = $args->{name};
    my $homepage     = $args->{homepage} // '';
    my $github       = $args->{github} // '';
    my $appstore     = $args->{appstore} // '';
    my $googleplay   = $args->{googleplay} // '';
    my $redirect_uri = $args->{redirect_uri} // '';

    ## do some validation
    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'AppRegister',
            message_to_client => $error,
        });
    };

    return $error_sub->(localize('Invalid URI for homepage.'))
        if length($homepage)
        and $homepage !~ m{^https?://};
    return $error_sub->(localize('Invalid URI for github.'))
        if length($github)
        and $github !~ m{^https?://(www\.)?github\.com/\S+$};
    return $error_sub->(localize('Invalid URI for appstore.'))
        if length($appstore)
        and $appstore !~ m{^https?://itunes\.apple\.com/\S+$};
    return $error_sub->(localize('Invalid URI for googleplay.'))
        if length($googleplay)
        and $googleplay !~ m{^https?://play\.google\.com/\S+$};

    my $oauth = BOM::Database::Model::OAuth->new;
    return $error_sub->(localize('The name is taken.'))
        if $oauth->is_name_taken($user_id, $name);

    my $app = $oauth->create_app({
        user_id      => $user_id,
        name         => $name,
        homepage     => $homepage,
        github       => $github,
        appstore     => $appstore,
        googleplay   => $googleplay,
        redirect_uri => $redirect_uri,
    });

    return $app;
}

sub list {
    my $params = shift;

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth = BOM::Database::Model::OAuth->new;
    return $oauth->get_apps_by_user_id($user_id);
}

sub get {
    my $params = shift;

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_get};
    my $app    = $oauth->get_app($user_id, $app_id);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AppGet',
            message_to_client => 'Not Found',
        }) unless $app;

    return $app;
}

sub delete {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my $params = shift;

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_delete};
    my $status = $oauth->delete_app($user_id, $app_id);

    return $status ? 1 : 0;
}

1;

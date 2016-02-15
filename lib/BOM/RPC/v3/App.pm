package BOM::RPC::v3::App;

use 5.014;
use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::OAuth;

sub __pre_hook {
    my ($params) = @_;
    return unless $params->{client_loginid};
    return BOM::Platform::Client->new({loginid => $params->{client_loginid}});
}

sub register {
    my $params = shift;

    return BOM::RPC::v3::Utility::invalid_token_error()
        if (exists $params->{token} and defined $params->{token} and not BOM::RPC::v3::Utility::token_to_loginid($params->{token}));

    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

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

    return BOM::RPC::v3::Utility::invalid_token_error()
        if (exists $params->{token} and defined $params->{token} and not BOM::RPC::v3::Utility::token_to_loginid($params->{token}));

    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth = BOM::Database::Model::OAuth->new;
    return $oauth->get_apps_by_user_id($user_id);
}

sub get {
    my $params = shift;

    return BOM::RPC::v3::Utility::invalid_token_error()
        if (exists $params->{token} and defined $params->{token} and not BOM::RPC::v3::Utility::token_to_loginid($params->{token}));

    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

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

    return BOM::RPC::v3::Utility::invalid_token_error()
        if (exists $params->{token} and defined $params->{token} and not BOM::RPC::v3::Utility::token_to_loginid($params->{token}));

    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_delete};
    my $status = $oauth->delete_app($user_id, $app_id);

    return $status ? 1 : 0;
}

1;

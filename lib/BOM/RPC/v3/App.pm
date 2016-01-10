package BOM::RPC::v3::App;

use 5.014;
use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize request);
use BOM::Database::Model::OAuth;

sub __pre_hook {
    my ($params) = @_;
    BOM::Platform::Context::request()->language($params->{language}) if $params->{language};
    return unless $params->{client_loginid};
    return BOM::Platform::Client->new({loginid => $params->{client_loginid}});
}

sub __oauth {
    state $oauth = BOM::Database::Model::OAuth->new;
    return $oauth;
}

sub register {
    my $params = shift;
    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $args       = $params->{args};
    my $name       = $args->{name};
    my $homepage   = $args->{homepage} // '';
    my $github     = $args->{github} // '';
    my $appstore   = $args->{appstore} // '';
    my $googleplay = $args->{googleplay} // '';

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
        and $googleplay !~ m{^https?://play\.google\.com/store/apps/\S+$};

    my $oauth = __oauth();
    return $error_sub->(localize('The name is taken.'))
        if $oauth->is_name_taken($user_id, $name);

    my $app = $oauth->create_client({
        user_id    => $user_id,
        name       => $name,
        homepage   => $homepage,
        github     => $github,
        appstore   => $appstore,
        googleplay => $googleplay,
    });

    return $app;
}

sub list {
    my $params = shift;
    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth = __oauth();
    return $oauth->get_clients_by_user_id($user_id);
}

sub get {
    my $params = shift;
    return BOM::RPC::v3::Utility::permission_error() unless my $client = __pre_hook($params);

    my $user = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth     = __oauth();
    my $client_id = $params->{args}->{app_get};
    my $app       = $oauth->get_client($user_id, $client_id);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AppGet',
            message_to_client => 'Not Found',
        }) unless $app;

    return $app;
}

1;

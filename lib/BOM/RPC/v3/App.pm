package BOM::RPC::v3::App;

use 5.014;
use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::OAuth;
use BOM::Database::ClientDB;
use Date::Utility;
use DataDog::DogStatsd::Helper;

sub register {
    my $params = shift;

    my $client  = $params->{client};
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $args                  = $params->{args};
    my $name                  = $args->{name};
    my $scopes                = $args->{scopes};
    my $homepage              = $args->{homepage} // '';
    my $github                = $args->{github} // '';
    my $appstore              = $args->{appstore} // '';
    my $googleplay            = $args->{googleplay} // '';
    my $redirect_uri          = $args->{redirect_uri} // '';
    my $verification_uri      = $args->{verification_uri} // '';
    my $app_markup_percentage = $args->{app_markup_percentage} // 0;

    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'AppRegister',
            message_to_client => $error,
        });
    };

    if (my $err = __validate_app_links($homepage, $github, $appstore, $googleplay, $redirect_uri, $verification_uri)) {
        return $error_sub->($err);
    }

    my $oauth = BOM::Database::Model::OAuth->new;
    return $error_sub->(localize('The name is taken.'))
        if $oauth->is_name_taken($user_id, $name);

    my $app = $oauth->create_app({
        user_id               => $user_id,
        name                  => $name,
        scopes                => $scopes,
        homepage              => $homepage,
        github                => $github,
        appstore              => $appstore,
        googleplay            => $googleplay,
        redirect_uri          => $redirect_uri,
        verification_uri      => $verification_uri,
        app_markup_percentage => $app_markup_percentage
    });

    return $app;
}

sub update {
    my $params = shift;

    my $client  = $params->{client};
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $args                  = $params->{args};
    my $app_id                = $args->{app_update};
    my $name                  = $args->{name};
    my $scopes                = $args->{scopes};
    my $homepage              = $args->{homepage} // '';
    my $github                = $args->{github} // '';
    my $appstore              = $args->{appstore} // '';
    my $googleplay            = $args->{googleplay} // '';
    my $redirect_uri          = $args->{redirect_uri} // '';
    my $verification_uri      = $args->{verification_uri} // '';
    my $app_markup_percentage = $args->{app_markup_percentage} // 0;

    ## do some validation
    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'AppUpdate',
            message_to_client => $error,
        });
    };

    my $oauth = BOM::Database::Model::OAuth->new;

    my $app = $oauth->get_app($user_id, $app_id);
    return $error_sub->(localize('Not Found')) unless $app;

    if (my $err = __validate_app_links($homepage, $github, $appstore, $googleplay, $redirect_uri, $verification_uri)) {
        return $error_sub->($err);
    }

    if ($app->{name} ne $name) {
        return $error_sub->(localize('The name is taken.'))
            if $oauth->is_name_taken($user_id, $name);
    }

    $app = $oauth->update_app(
        $app_id,
        {
            name                  => $name,
            scopes                => $scopes,
            homepage              => $homepage,
            github                => $github,
            appstore              => $appstore,
            googleplay            => $googleplay,
            redirect_uri          => $redirect_uri,
            verification_uri      => $verification_uri,
            app_markup_percentage => $app_markup_percentage
        });

    return $app;
}

sub __validate_app_links {
    my ($homepage, $github, $appstore, $googleplay) = @_;

    my @sites = @_;
    my $validation_error;

    for (grep { length($_) } @sites) {
        $validation_error = BOM::RPC::v3::Utility::validate_uri($_);
        return $validation_error if $validation_error;
    }

    return localize('Invalid URI for homepage.')
        if length($homepage)
        and $homepage !~ m{^https?://};
    return localize('Invalid URI for github.')
        if length($github)
        and $github !~ m{^https?://(www\.)?github\.com/\S+$};
    return localize('Invalid URI for appstore.')
        if length($appstore)
        and $appstore !~ m{^https?://itunes\.apple\.com/\S+$};
    return localize('Invalid URI for googleplay.')
        if length($googleplay)
        and $googleplay !~ m{^https?://play\.google\.com/\S+$};

    return;
}

sub list {
    my $params = shift;

    my $client  = $params->{client};
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth = BOM::Database::Model::OAuth->new;
    return $oauth->get_apps_by_user_id($user_id);
}

sub get {
    my $params = shift;

    my $client  = $params->{client};
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_get};
    my $app    = $oauth->get_app($user_id, $app_id);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AppGet',
            message_to_client => localize('Not Found'),
        }) unless $app;

    return $app;
}

sub delete {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my $params = shift;

    my $client  = $params->{client};
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $user_id = $user->id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_delete};
    my $status = $oauth->delete_app($user_id, $app_id);

    return $status ? 1 : 0;
}

sub oauth_apps {
    my $params = shift;

    my $client = $params->{client};

    my $oauth = BOM::Database::Model::OAuth->new;

    return $oauth->get_used_apps_by_loginid($client->loginid);
}

sub revoke_oauth_app {
    my $params = shift;

    my $client = $params->{client};
    my $oauth  = BOM::Database::Model::OAuth->new;
    my $user   = BOM::Platform::User->new({email => $client->email});
    my $status = 1;
    foreach my $c1 ($user->clients) {
        $status &&= $oauth->revoke_app($params->{args}{revoke_oauth_app}, $c1->loginid);
    }

    return $status;
}

sub verify_app {
    my $params = shift;

    my $app_id = $params->{app_id} || '';
    my $app;

    my $oauth = BOM::Database::Model::OAuth->new;

    # app id field = Postgres BIGINT, range: -9223372036854775808 to 9223372036854775807  (19 digits)
    if ($app_id !~ /^(?!0)[0-9]{1,19}$/ or not($app = $oauth->verify_app($app_id))) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidAppID',
            message_to_client => localize('Your app_id is invalid.'),
        });
    }

    return {
        stash => {
            valid_source          => $app_id,
            app_markup_percentage => $app->{app_markup_percentage} // 0
        }};
}

sub app_markup_details {
    my $params  = shift;
    my $args    = $params->{args};
    my $client  = $params->{client};
    my $oauth   = BOM::Database::Model::OAuth->new;
    my $user    = BOM::Platform::User->new({email => $client->email});
    my $app_ids = $oauth->get_app_ids_by_user_id($user->id);

    # If the app_id they have submitted is not in the list we have associated with them, then...
    if ($args->{app_id} && !grep { $args->{app_id} == $_ } @$app_ids) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidAppID',
            message_to_client => localize('Your app_id is invalid.'),
        });
    } elsif ($args->{app_id}) {
        $app_ids = [$args->{app_id}];
    }

    my $time_from = Date::Utility->new($args->{date_time_from})->datetime_yyyymmdd_hhmmss;
    my $time_to   = Date::Utility->new($args->{date_time_to})->datetime_yyyymmdd_hhmmss;

    my $clientdb = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'replica',
        })->db;

    return {
        transactions => $clientdb->dbh->selectall_arrayref(
            'SELECT * FROM reporting.get_app_markup_details(?,?,?,?,?,?,?,?)',
            {Slice => {}},
            __arrayref_to_db_array($app_ids),
            $time_from,
            $time_to,
            $args->{offset}         || undef,
            $args->{limit}          || undef,
            $args->{client_loginid} || undef,
            $args->{sort_fields}    || undef,
            $args->{sort}           || undef
        )};
}

# turn this perl [1,2,3] into this text {1,2,3}
sub __arrayref_to_db_array {
    return "{" . join(',', @{(shift)}) . "}";
}

1;

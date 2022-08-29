package BOM::RPC::v3::App;

use 5.014;
use strict;
use warnings;

use Syntax::Keyword::Try;

use BOM::RPC::v3::Utility  qw(log_exception);
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::OAuth;
use BOM::Database::ClientDB;
use BOM::Platform::Event::Emitter;
use Date::Utility;
use DataDog::DogStatsd::Helper;

use BOM::RPC::Registry '-dsl';

requires_auth('wallet');

rpc app_register => sub {
    my $params = shift;

    my $client  = $params->{client};
    my $user_id = $client->user_id;

    my $args                  = $params->{args};
    my $name                  = $args->{name};
    my $scopes                = $args->{scopes};
    my $homepage              = $args->{homepage}              // '';
    my $github                = $args->{github}                // '';
    my $appstore              = $args->{appstore}              // '';
    my $googleplay            = $args->{googleplay}            // '';
    my $redirect_uri          = $args->{redirect_uri}          // '';
    my $verification_uri      = $args->{verification_uri}      // '';
    my $app_markup_percentage = $args->{app_markup_percentage} // 0;

    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'AppRegister',
            message_to_client => $error,
        });
    };

    if (my $err = __validate_redirect_uri($redirect_uri, $app_markup_percentage)) {
        return $error_sub->($err);
    }

    if (my $err = __validate_app_links($homepage, $github, $appstore, $googleplay, $redirect_uri, $verification_uri)) {
        return $error_sub->($err);
    }

    my $oauth = BOM::Database::Model::OAuth->new;
    return $error_sub->(localize('The name is taken.'))
        if $oauth->is_name_taken($user_id, $name);

    my $payload = {
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
    };
    my $app = $oauth->create_app($payload);

    delete $payload->{user_id};
    $payload->{loginid} = $client->loginid;
    $payload->{app_id}  = $app->{app_id};

    BOM::Platform::Event::Emitter::emit('app_registered', $payload);

    return $app;
};

rpc app_update => sub {
    my $params = shift;

    my $client  = $params->{client};
    my $user_id = $client->user_id;

    my $args                  = $params->{args};
    my $app_id                = $args->{app_update};
    my $name                  = $args->{name};
    my $scopes                = $args->{scopes};
    my $homepage              = $args->{homepage};
    my $github                = $args->{github};
    my $appstore              = $args->{appstore};
    my $googleplay            = $args->{googleplay};
    my $redirect_uri          = $args->{redirect_uri};
    my $verification_uri      = $args->{verification_uri};
    my $app_markup_percentage = $args->{app_markup_percentage};

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

    if (my $err = __validate_redirect_uri($redirect_uri, $app_markup_percentage)) {
        return $error_sub->($err);
    }

    if (my $err = __validate_app_links($homepage, $github, $appstore, $googleplay, $redirect_uri, $verification_uri)) {
        return $error_sub->($err);
    }

    if ($app->{name} ne $name) {
        return $error_sub->(localize('The name is taken.'))
            if $oauth->is_name_taken($user_id, $name);
    }

    my $payload = {
        name                  => $name,
        scopes                => $scopes,
        homepage              => $homepage,
        github                => $github,
        appstore              => $appstore,
        googleplay            => $googleplay,
        redirect_uri          => $redirect_uri,
        verification_uri      => $verification_uri,
        app_markup_percentage => $app_markup_percentage
    };

    my @updated_fields = grep { defined($args->{$_}) and ($args->{$_} ne $app->{$_} // '') } keys %$payload;

    $app = $oauth->update_app($app_id, $payload);

    BOM::Platform::Event::Emitter::emit(
        'app_updated',
        {
            $payload->%{@updated_fields},
            loginid => $client->loginid,
            app_id  => $app_id,
        });

    return $app;
};

sub __validate_app_links {
    my @sites = @_;
    my $validation_error;

    for (grep { length($_) } @sites) {
        next if $_ =~ m{^https?://play\.google\.com/store/apps/details\?id=[\w.]+$};
        $validation_error = BOM::RPC::v3::Utility::validate_uri($_);
        return $validation_error if $validation_error;
    }

    return;
}

rpc app_list => sub {
    my $params = shift;

    my $client  = $params->{client};
    my $user_id = $client->user_id;

    my $oauth = BOM::Database::Model::OAuth->new;
    return $oauth->get_apps_by_user_id($user_id);
};

rpc app_get => sub {
    my $params = shift;

    my $client  = $params->{client};
    my $user_id = $client->user_id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_get};
    my $app    = $oauth->get_app($user_id, $app_id);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AppGet',
            message_to_client => localize('Not Found'),
        }) unless $app;

    return $app;
};

rpc app_delete => sub {
    my $params = shift;

    my $client  = $params->{client};
    my $user_id = $client->user_id;

    my $oauth  = BOM::Database::Model::OAuth->new;
    my $app_id = $params->{args}->{app_delete};
    my $status = $oauth->block_app($app_id, $user_id);

    BOM::Platform::Event::Emitter::emit(
        'app_deleted',
        {
            loginid => $client->loginid,
            app_id  => $app_id
        }) if $status;

    return $status ? 1 : 0;
};

rpc oauth_apps => sub {
    my $params = shift;

    my $client = $params->{client};

    my $oauth = BOM::Database::Model::OAuth->new;

    return $oauth->get_used_apps_by_loginid($client->loginid);
};

rpc revoke_oauth_app => sub {
    my $params = shift;

    my $client = $params->{client};
    my $oauth  = BOM::Database::Model::OAuth->new;
    my $user   = $client->user;
    my $status = 1;
    foreach my $c1 ($user->clients) {
        $status &&= $oauth->revoke_app($params->{args}{revoke_oauth_app}, $c1->loginid);
    }

    return $status;
};

# Not an RPC
sub verify_app {
    my $params = shift;

    my $app_id = $params->{app_id} || '';
    my $app;

    my $oauth = BOM::Database::Model::OAuth->new;

    # app id field = Postgres BIGINT, range: -9223372036854775808 to 9223372036854775807  (19 digits)
    if ($app_id !~ /^(?!0)[0-9]{1,19}$/ or not($app = $oauth->verify_app($app_id))) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidAppID',
            message_to_client => localize('Your [_1] is invalid.', 'app_id'),
        });
    }

    return {
        stash => {
            valid_source               => $app_id,
            app_markup_percentage      => $app->{app_markup_percentage} // 0,
            source_bypass_verification => $app->{bypass_verification}   // 0
        }};
}

rpc app_markup_details => sub {
    my $params  = shift;
    my $args    = $params->{args};
    my $client  = $params->{client};
    my $oauth   = BOM::Database::Model::OAuth->new;
    my $user_id = $client->user_id;
    my $app_ids = ();

    # If the app_id they have submitted is not in the list we have associated with them, then...
    if ($args->{app_id}) {
        unless ($oauth->user_has_app_id($user_id, $args->{app_id})) {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAppID',
                message_to_client => localize('Your [_1] is invalid.', 'app_id'),
            });
        } else {
            $app_ids = [$args->{app_id}];
        }
    } else {
        $app_ids = $oauth->get_app_ids_by_user_id($user_id);
    }

    my ($time_from, $time_to);
    try {
        $time_from = Date::Utility->new($args->{date_from})->datetime_yyyymmdd_hhmmss;
        $time_to   = Date::Utility->new($args->{date_to})->datetime_yyyymmdd_hhmmss;
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDateFormat',
                message_to_client => localize('Invalid date format.'),
            })
    }

    my $clientdb = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'replica',
        })->db;

    return {
        transactions => $clientdb->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM reporting.get_app_markup_details(?,?,?,?,?,?,?,?)',
                    {Slice => {}},
                    $app_ids, $time_from, $time_to,
                    $args->{offset}         || undef,
                    $args->{limit}          || 1000,
                    $args->{client_loginid} || undef,
                    $args->{sort_fields}    || undef,
                    $args->{sort}           || undef
                );
            })};
};

rpc app_markup_statistics => sub {
    my $params    = shift;
    my $args      = $params->{args};
    my $client    = $params->{client};
    my $user_id   = $client->user_id;
    my $oauth     = BOM::Database::Model::OAuth->new;
    my $collector = BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic;
    my $app_ids   = $oauth->get_app_ids_by_user_id($user_id);

    my ($time_from, $time_to);
    try {
        $time_from = Date::Utility->new($args->{date_from})->datetime_yyyymmdd_hhmmss;
        $time_to   = Date::Utility->new($args->{date_to})->datetime_yyyymmdd_hhmmss;
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDateFormat',
                message_to_client => localize('Invalid date format.'),
            })
    }

    my $res = {
        breakdown => $collector->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM data_collection.get_app_markup_statistics(?,?,?)',
                    {Slice => {}},
                    $app_ids, $time_from, $time_to
                );
            })};
    foreach my $row ($res->{breakdown}->@*) {
        $res->{total_app_markup_usd}     += $row->{app_markup_usd};
        $res->{total_transactions_count} += $row->{transactions_count};
    }
    return $res;
};

=head2 __validate_redirect_uri

    __validate_redirect_uri($redirect_uri, $app_markup_percentage);

validate redirect_uri exists on charging markup

The following arguments are used

=over 4

=item * C<redirect_uri> redirect URL

=item * C<app_markup_percentage> markup charge percentage

=back

=cut

sub __validate_redirect_uri {
    my ($redirect_uri)          = shift // '';
    my ($app_markup_percentage) = shift // 0;

    if (($app_markup_percentage + 0) > 0 && $redirect_uri eq '') {
        return localize('Please provide redirect url.');
    }

    return;
}

1;

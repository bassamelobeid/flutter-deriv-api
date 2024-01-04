package BOM::TradingPlatform::MT5;

use strict;
use warnings;
no indirect;

use List::Util qw(any first);

use Syntax::Keyword::Try;

use BOM::Config::MT5;
use BOM::Config::Compliance;
use BOM::Config::Runtime;
use BOM::MT5::User::Async;
use BOM::Platform::Context qw (localize request);
use BOM::User::Utility;
use JSON::MaybeXS              qw{decode_json};
use DataDog::DogStatsd::Helper qw(stats_inc);
use Log::Any                   qw($log);
use LandingCompany::Registry;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Brands;

use Format::Util::Numbers qw(financialrounding formatnumber);

=head1 NAME 

BOM::TradingPlatform::MT5 - The MetaTrader5 trading platform implementation.

=head1 SYNOPSIS 

    my $mt5 = BOM::TradingPlatform::MT5->new(client => $client);
    my $account = $mt5->new_account(...)
    $mt5->deposit(account => $account, ...);

=head1 DESCRIPTION 

Provides a high level implementation of the MetaTrader5 API.

Exposes MetaTrader5 API through our trading platform interface.

This module must provide support to each MetaTrader5 integration within our systems.

=cut

use parent qw( BOM::TradingPlatform );

use constant {MT5_REGEX => qr/^MT[DR]?(?=\d+$)/};

=head2 create_error_future

create error handling for future object.

create_error_future({code => "MT5AccountInactive", message => "Account is inactive"})

=over 4

=item * C<code> (required). the error code.

=item * C<details> (required). the error details.

=back

=cut

sub create_error_future {
    my $err            = shift;
    my $error_registry = BOM::RPC::v3::MT5::Errors->new();

    if (ref $err eq 'HASH') {
        if ($err->{code}) {
            return Future->fail($error_registry->format_error($err->{code}, $err->{message}));
        } else {
            return Future->fail({error => $err->{message}});
        }
    } else {
        return Future->fail($err);
    }
}

=head2 new

Creates and returns a new L<BOM::TradingPlatform::MT5> instance.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {client => $args{client}}, $class;
}

=head2 change_password

Changes the password of MT5 accounts.

Takes the following arguments as named parameters:

=over 4

=item * C<password> (required). the new password.

=back

Returns a hashref of loginids, or dies with error.

=cut

sub change_password {
    my ($self, %args) = @_;

    my $password = $args{password};

    my @mt5_loginids = $self->client->user->get_mt5_loginids();

    my (@valid_logins, $res);

    for (@mt5_loginids) {
        my $group      = $self->get_group($_);
        my $server_key = BOM::MT5::User::Async::get_trading_server_key({login => $_}, $group);

        push $res->{failed_logins}->@*, $_ if $self->is_mt5_server_suspended($group, $server_key);
    }

    # We do not want to continue if one of the user trading server is suspended
    return $res if $res->{failed_logins};

    my @mt5_users_get = map {
        my $login = $_;

        _check_same_password($login, $password, 'investor')->then(
            sub {
                BOM::MT5::User::Async::get_user($login);
            }
        )->set_label($login)
    } @mt5_loginids;

    Future->wait_all(@mt5_users_get)->then(
        sub {
            for my $result (@_) {
                if ($result->is_done) {
                    push @valid_logins, $result->label;
                    next;
                }

                my $error_code = (ref $result->failure eq 'HASH') ? $result->failure->{code} // '' : '';

                die $result->failure if $error_code eq 'SameAsInvestorPassword';

                # NotFound error indicates an archived account which should be ignored
                push $res->{failed_logins}->@*, $result->label unless $error_code eq 'NotFound';
            }
        })->get;

    unless (@mt5_loginids) {
        $self->client->user->update_trading_password($password);
        return;
    }

    my @mt5_password_change =
        map { BOM::MT5::User::Async::password_change({login => $_, new_password => $password, type => 'main'})->set_label($_) } @valid_logins;

    my $result = Future->wait_all(@mt5_password_change)->then(
        sub {
            push $res->{$_->is_failed ? 'failed_logins' : 'successful_logins'}->@*, $_->label for @_;
            Future->done($res);
        })->get;

    my ($successful_logins, $failed_logins) = $result->@{qw/successful_logins failed_logins/};

    if (not defined $failed_logins) {
        $self->client->user->update_trading_password($password);
    }

    return $result;
}

=head2 change_investor_password

Changes the investor password of an MT5 account.

Takes the following arguments as named parameters:

=over 4

=item * C<$account_id> - an MT5 login

=item * C<new_password> (required). the new password.

=item * C<old_password> (optional). the old password for validation.

=back

Returns a Future object, throws exception on error

=cut

sub change_investor_password {
    my ($self, %args) = @_;

    my ($new_password, $account_id) = @args{qw/new_password account_id/};

    my @mt5_loginids = $self->client->user->get_mt5_loginids();
    my $mt5_login    = first { $_ eq $account_id } @mt5_loginids;

    die +{error_code => 'MT5InvalidAccount'} unless $mt5_login;

    my $old_password = $args{old_password};

    return _check_same_password($account_id, $new_password, 'main')->then(
        sub {
            return BOM::MT5::User::Async::password_check({
                    login    => $account_id,
                    password => $old_password,
                    type     => 'investor',
                }) if $old_password;

            return Future->done;
        }
    )->then(
        sub {
            BOM::MT5::User::Async::password_change({
                login        => $account_id,
                new_password => $new_password,
                type         => 'investor',
            });
        });
}

=head2 _check_same_password

Checks if the requested password is the same as an existing MT5 passwords.
It fails if the password is correct (the same as the target password) and 
succeeds only if the password is incorrect (isn't the same as the traget password).
It takes the following args:

=over 4

=item * C<login> - an MT5 login or account ID.

=item * C<password> - the password to check.

=item * C<type> - the password type to check.

=back

=cut

sub _check_same_password {
    my ($login, $password, $type) = @_;

    my $error_code = $type eq 'main' ? 'SameAsMainPassword' : 'SameAsInvestorPassword';

    return BOM::MT5::User::Async::password_check({
            login    => $login,
            password => $password,
            type     => $type,
        }
    )->then(
        sub {
            return Future->fail({code => $error_code});
        }
    )->else(
        sub {
            my ($error) = @_;

            if (ref $error eq 'HASH' && $error->{code} && $error->{code} eq 'InvalidPassword') {
                return Future->done();
            }

            return Future->fail(@_);
        });
}

=head2 get_account_info

The MT5 implementation of getting an account info by loginid.

=over 4

=item * C<$loginid> - an MT5 loginid

=back

Returns a Future object holding an MT5 account info on success, throws exception on error

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    my @mt5_logins = $self->client->user->mt5_logins;
    my $mt5_login  = first { $_ eq $loginid } @mt5_logins;

    die "InvalidMT5Account\n" unless ($mt5_login);

    my $mt5_user  = BOM::MT5::User::Async::get_user($mt5_login)->get;
    my $mt5_group = BOM::User::Utility::parse_mt5_group($mt5_user->{group});
    my $currency  = uc($mt5_group->{currency});

    return {
        account_id            => $mt5_user->{login},
        account_type          => $mt5_group->{account_type},
        balance               => financialrounding('amount', $currency, $mt5_user->{balance}),
        currency              => $currency,
        display_balance       => formatnumber('amount', $currency, $mt5_user->{balance}) // '0.00',
        platform              => 'mt5',
        market_type           => $mt5_group->{market_type},
        landing_company_short => $mt5_group->{landing_company_short},
        sub_account_type      => $mt5_group->{sub_account_type},
    };
}

=head2 available_accounts

Returns a list of available trading accounts for a given user.

=over 4

=item * C<country_code> - 2 letter country code

=back

=cut

sub available_accounts {
    my ($self, $args) = @_;

    unless ($args->{country_code}) {
        $log->debugf("CountryCodeRequired Exception > Client ID: %s, Binary User ID: %s", $self->client->loginid, $self->client->binary_user_id);
        die 'CountryCodeRequired';
    }

    # If brand is not provided, it will default to deriv.
    my $brand = $args->{brand} // Brands->new;

    my $accounts = $brand->countries_instance->mt_account_types_for_country($args->{country_code});

    return [] unless $accounts->%*;

    my @trading_accounts;
    foreach my $market_type (sort keys $accounts->%*) {
        foreach my $account ($accounts->{$market_type}->@*) {
            my $lc                        = LandingCompany::Registry->by_name($account->{company});
            my $jurisdiction_ratings      = BOM::Config::Compliance->new()->get_jurisdiction_risk_rating('mt5')->{$lc->short} // {};
            my $restricted_risk_countries = {map { $_ => 1 } @{$jurisdiction_ratings->{restricted} // []}};
            next if $restricted_risk_countries->{$args->{country_code}};

            push @trading_accounts,
                +{
                shortcode                  => $lc->short,
                name                       => $lc->name,
                requirements               => $lc->requirements,
                sub_account_type           => $account->{sub_account_type},
                market_type                => $account->{market_type},
                linkable_landing_companies => $lc->mt5_require_deriv_account_at,
                };
        }
    }

    return \@trading_accounts;
}

=head1 Non-RPC methods

=head2 config

Generates and caches configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= do {
        my $config = BOM::Config::MT5->new;
        $config;
    }
}

=head2 is_mt5_server_suspended

Returns 1 if MT5 server is currently suspended, returns 0 otherwise

=cut

sub is_mt5_server_suspended {
    my ($self, $group_type, $trade_server) = @_;

    my $app_config = BOM::Config::Runtime->instance->app_config->system->mt5;

    return $app_config->suspend->{$group_type}->{$trade_server}->all || $app_config->suspend->all;
}

=head2 get_group

Using regex to return what group the account id belongs to 

=cut

sub get_group {
    my ($self, $account_id) = @_;

    return 'real' if $account_id =~ /^MTR\d+$/;
    return 'demo' if $account_id =~ /^MTD\d+$/;
}

=head2 get_accounts

Gets all available client accounts and returns list formatted for websocket response.

Takes the following arguments as named parameters:

=over 4

=item * C<force>. If true, an error will be raised if any accounts are inaccessible.

=item * C<type>. Filter accounts to real or demo.

=back

=cut

sub get_accounts {
    my ($self, %args) = @_;
    my $account_type = $args{type};

    return mt5_accounts_lookup($self->client, $account_type)->then(
        sub {
            my (@logins) = @_;
            my @valid_logins = grep { defined $_ and $_ } @logins;

            return Future->done(\@valid_logins);
        })->get;
}

=head2 mt5_accounts_lookup

$mt5_logins = mt5_accounts_lookup($client)

Takes Client object and tries to fetch MT5 account information for each loginid
If loginid-related account does not exist on MT5, undef will be attached to the list

Takes the following parameter:

=over 4

=item * C<params> hashref that contains a C<BOM::User::Client>

=item * C<params> string to represent account type (gaming|demo|financial) or default to undefined.

=back

Returns a Future holding list of MT5 account information (or undef) or a failed future with error information

=cut

sub mt5_accounts_lookup {
    my ($client, $account_type) = @_;
    my %allowed_error_codes = (
        ConnectionTimeout           => 1,
        MT5AccountInactive          => 1,
        NetworkError                => 1,
        NoConnection                => 1,
        NotFound                    => 1,
        ERR_NOSERVICE               => 1,
        'Service is not available.' => 1,
        'Timed out'                 => 1,
        'Connection closed'         => 1
    );

    my @futures;
    $account_type = $account_type ? $account_type : 'all';
    my $wallet_loginid = $client->is_wallet ? $client->loginid : undef;
    my @clients        = $client->user->get_mt5_loginids(
        type_of_account => $account_type,
        wallet_loginid  => $wallet_loginid
    );

    for my $login (@clients) {
        my $f = get_settings($client, $login)->then(
            sub {
                my ($setting) = @_;

                $setting = _filter_settings($setting,
                    qw/account_type balance country currency display_balance email group landing_company_short leverage login name market_type sub_account_type server server_info/
                ) if !$setting->{error};
                return Future->done($setting);
            }
        )->catch(
            sub {
                my ($resp) = @_;

                if ((
                        ref $resp eq 'HASH' && defined $resp->{error} && ref $resp->{error} eq 'HASH' && ($allowed_error_codes{$resp->{error}{code}}
                            || $allowed_error_codes{$resp->{error}{message_to_client}}))
                    || $allowed_error_codes{$resp})
                {
                    log_stats($login, $resp);
                    return Future->done(undef);
                } else {
                    $log->errorf("mt5_accounts_lookup Exception: %s", $resp);
                }

                return Future->fail($resp);
            });
        push @futures, $f;
    }

    # The reason for using wait_all instead of fmap here is:
    # to guaranty the MT5 circuit breaker test request will not be canceled when failing the other requests.
    # Note: using ->without_cancel to avoid cancel the future is not working
    # because our RPC is not totally async, where the worker will start processing another request after return the response
    # so the future in the background will never end
    return Future->wait_all(@futures)->then(
        sub {
            my @futures_result = @_;
            my $failed_future  = first { $_->is_failed } @futures_result;
            return Future->fail($failed_future->failure) if $failed_future;

            my @result = map { $_->result } @futures_result;
            return Future->done(@result);
        });
}

=head2 get_assets

Get assets listing from MT5

=over 4

=back

Returns a Future object holding an MT5 account info on success, throws exception on error

=cut

sub get_assets {
    my ($self, $type, $region) = @_;

    my $redis                 = BOM::Config::Redis::redis_mt5_user();
    my $asset_listing         = decode_json($redis->get('MT5::ASSETS') // '{}');
    my $suspended_underlyings = BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy;

    my @res = ();

    for my $asset ($asset_listing->{assets}->@*) {

        my @tokens              = split(",", $asset->{availability});
        my %region_availability = map { $_ => 1 } @tokens;
        my $asset_shortcode     = $asset->{shortcode};
        next if grep { /^$asset_shortcode$/ } $suspended_underlyings->@*;
        next unless $region_availability{$region};
        next if $type eq 'brief' and $asset->{display_order} == 10000;
        my %new_asset = map { lc $_ => $asset->{$_} } keys $asset->%*;
        $new_asset{symbol} = localize($new_asset{symbol});
        delete $new_asset{availability};
        push @res, \%new_asset;
    }

    return \@res;
}

=head2 get_settings

    $user_mt5_settings = get_settings($client,login)

Takes a client object and a hash reference as inputs and returns the details of
the MT5 user, based on the MT5 login id passed.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains the MT5 login id
under C<login> key.

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5GetUserError>.

=back

=back

=item * A hashref that contains the details of the user's MT5 account.

=back

=cut

sub get_settings {
    my ($client, $login) = @_;

    if (BOM::MT5::User::Async::is_suspended('', {login => $login})) {
        my $account_type  = BOM::MT5::User::Async::get_account_type($login);
        my $server        = BOM::MT5::User::Async::get_trading_server_key({login => $login}, $account_type);
        my $server_config = BOM::Config::MT5->new(
            group_type  => $account_type,
            server_type => $server
        )->server_by_id();
        my $resp = {
            error => {
                code    => 'MT5AccountInaccessible',
                details => {
                    login        => $login,
                    account_type => $account_type,
                    server       => $server,
                    server_info  => {
                        id          => $server,
                        geolocation => $server_config->{$server}{geolocation},
                        environment => $server_config->{$server}{environment},
                    }
                },
                message_to_client => localize('MT5 is currently unavailable. Please try again later.'),
            }};
        return Future->done($resp);
    }

    return _get_user_with_group($login)->then(
        sub {
            my ($settings) = @_;

            return create_error_future({code => 'MT5AccountInactive'}) if !$settings->{active};

            $settings = _filter_settings($settings,
                qw/account_type address balance city company country currency display_balance email group landing_company_short leverage login market_type name phone phonePassword state sub_account_type zipCode server server_info/
            );

            return Future->done($settings);
        }
    )->catch(
        sub {
            my $err = shift;

            return create_error_future($err);
        });
}

=head2 _filter_settings

filter accounts with only the allowed settings/params.

=cut

sub _filter_settings {
    my ($settings, @allowed_keys) = @_;
    my $filtered_settings = {};

    @{$filtered_settings}{@allowed_keys} = @{$settings}{@allowed_keys};
    $filtered_settings->{market_type} = 'synthetic' if $filtered_settings->{market_type} and $filtered_settings->{market_type} eq 'gaming';

    return $filtered_settings;
}

=head2 _get_user_with_group

fetching mt5 users with their group.

=cut

sub _get_user_with_group {
    my ($loginid) = shift;

    return BOM::MT5::User::Async::get_user($loginid)->then(
        sub {
            my ($settings) = @_;
            return create_error_future({
                    code    => 'MT5GetUserError',
                    message => $settings->{error}}) if (ref $settings eq 'HASH' and $settings->{error});
            if (my $country = $settings->{country}) {
                my $country_code = Locale::Country::Extra->new()->code_from_country($country);
                if ($country_code) {
                    $settings->{country} = $country_code;
                } else {
                    $log->warnf("Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra");
                }
            }
            return Future->done($settings);
        }
    )->then(
        sub {
            my ($settings) = @_;
            return BOM::MT5::User::Async::get_group($settings->{group})->then(
                sub {
                    my ($group_details) = @_;
                    return create_error_future({
                            code    => 'MT5GetGroupError',
                            message => $group_details->{error}}) if (ref $group_details eq 'HASH' and $group_details->{error});
                    $settings->{currency}        = $group_details->{currency};
                    $settings->{landing_company} = $group_details->{company};
                    $settings->{display_balance} = formatnumber('amount', $settings->{currency}, $settings->{balance});

                    _set_mt5_account_settings($settings) if ($settings->{group});

                    return Future->done($settings);
                });
        }
    )->catch(
        sub {
            my $err = shift;

            return create_error_future($err);
        });
}

=head2 _set_mt5_account_settings

populate mt5 accounts with settings.

=cut

sub _set_mt5_account_settings {
    my ($account) = shift;

    my $group_name = lc($account->{group});
    my $config     = BOM::Config::mt5_account_types()->{$group_name};
    $account->{server}                = $config->{server};
    $account->{active}                = $config->{landing_company_short} ? 1 : 0;
    $account->{landing_company_short} = $config->{landing_company_short};
    $account->{market_type}           = $config->{market_type};
    $account->{account_type}          = $config->{account_type};
    $account->{sub_account_type}      = $config->{sub_account_type};

    if ($config->{server}) {
        my $server_config = BOM::Config::MT5->new(group => $group_name)->server_by_id();
        $account->{server_info} = {
            id          => $config->{server},
            geolocation => $server_config->{$config->{server}}{geolocation},
            environment => $server_config->{$config->{server}}{environment},
        };
    }
}

=head2 log_stats

Adds DD metrics related to 'mt5_accounts_lookup' allowed error codes

Takes the following parameters:

=over 4

=item * C<login> login of the user

=item * C<resp> response containing the allowed error code info

=back

=cut

sub log_stats {

    my ($login, $resp) = @_;

    my $error_code    = $resp;
    my $error_message = $resp;

    if (ref $resp eq 'HASH') {
        $error_code    = $resp->{error}{code};
        $error_message = $resp->{error}{message_to_client};
    }

    # 'NotFound' error occurs if a user has at least one archived MT5 account. Since it is very common for users to have multiple archived
    # MT5 accounts and since this error is not critical, we will be excluding it from DD
    unless ($error_code eq 'NotFound') {
        stats_inc("mt5.accounts.lookup.error.code", {tags => ["login:$login", "error_code:$error_code", "error_messsage:$error_message"]});
    }
}

1;

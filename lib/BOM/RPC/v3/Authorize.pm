package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;
use List::MoreUtils qw(any);
use Format::Util::Numbers qw/formatnumber/;

use BOM::User::Client;
use Brands;

use BOM::RPC::Registry '-dsl';

use BOM::User::AuditLog;
use BOM::RPC::v3::Utility;
use BOM::User;
use BOM::Platform::Context qw (localize request);
use BOM::RPC::v3::Utility;
use BOM::User;

use LandingCompany::Registry;

sub _get_upgradeable_landing_companies {
    my ($client_list, $client) = @_;

    # List to store upgradeable companies
    my @upgradeable_landing_companies;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;

    # Get the gaming and financial company from the client's residence
    my $gaming_company    = $countries_instance->gaming_company_for_country($client->residence);
    my $financial_company = $countries_instance->financial_company_for_country($client->residence);

    # Check if client has a gaming account or financial account
    # Otherwise, add them to the list
    # NOTE: Gaming has higher priority over financial
    if (   $gaming_company
        && $client->is_virtual
        && !(any { $_->landing_company->short eq $gaming_company } @$client_list))
    {
        push @upgradeable_landing_companies, $gaming_company;
    }

    # Some countries have financial but not gaming account
    if (  !$gaming_company
        && $financial_company
        && $client->is_virtual
        && !(any { $_->landing_company->short eq $financial_company } @$client_list))
    {
        push @upgradeable_landing_companies, $financial_company;
    }

    # In some cases, client has VRTC, MX/MLT, MF account
    # MX/MLT account might get duplicated, so MF should not have any companies
    if (@upgradeable_landing_companies && !$client->is_virtual) {
        @upgradeable_landing_companies = ();
    }

    # Some countries have both financial and gaming. Financial is added:
    # - if the list is empty
    # - two companies are not same
    # - current client is not virtual
    if (   !@upgradeable_landing_companies
        && ($gaming_company && $financial_company && $gaming_company ne $financial_company)
        && !$client->is_virtual
        && !(any { $_->landing_company->short eq $financial_company } @$client_list))
    {
        push @upgradeable_landing_companies, $financial_company;
    }

    # Multiple CR account scenario:
    # - client's landing company is CR
    # - client can upgrade to other CR accounts, assuming no fiat currency OR other cryptocurrencies
    if ($client->landing_company->short eq 'costarica') {

        # Get siblings of the current client
        my $siblings = BOM::RPC::v3::Utility::get_real_account_siblings_information($client->loginid);

        my ($fiat_check, $lc_num_crypto, $client_num_crypto) =
            BOM::RPC::v3::Utility::get_client_currency_information($siblings, $client->landing_company->short);

        my $cryptocheck = ($lc_num_crypto && $lc_num_crypto == $client_num_crypto);

        # Push to upgradeable_landing_companies, if possible to open another CR account
        push @upgradeable_landing_companies, 'costarica' if (!$fiat_check || !$cryptocheck);
    }

    return \@upgradeable_landing_companies;
}

rpc authorize => sub {
    my $params = shift;
    my ($token, $token_details, $client_ip) = @{$params}{qw/token token_details client_ip/};

    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});
    # temorary remove ua_fingerptint check
    #if ($token_details->{ua_fingerprint} && $token_details->{ua_fingerprint} ne $params->{ua_fingerprint}) {
    #    return BOM::RPC::v3::Utility::invalid_token_error();
    #}

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidToken',
            message_to_client => BOM::Platform::Context::localize("Token is not valid for current ip address.")}
    ) if (exists $token_details->{valid_for_ip} and $token_details->{valid_for_ip} ne $client_ip);

    my ($loginid, $scopes) = @{$token_details}{qw/loginid scopes/};

    my $client = BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    my ($lc, $brand_name) = ($client->landing_company, request()->brand);
    # check for not allowing cross brand tokens
    return BOM::RPC::v3::Utility::invalid_token_error() unless (grep { $brand_name eq $_ } @{$lc->allowed_for_brands});

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AccountDisabled',
            message_to_client => BOM::Platform::Context::localize("Account is disabled.")}
    ) unless BOM::RPC::v3::Utility::is_account_available($client);

    my ($user, $token_type) = (BOM::User->new({email => $client->email}));
    if (length $token == 15) {
        $token_type = 'api_token';
        # add to login history for api token only as oauth login already creates an entry
        if ($params->{args}->{add_to_login_history} && $user) {
            $user->add_login_history({
                environment => BOM::RPC::v3::Utility::login_env($params),
                successful  => 't',
                action      => 'login',
            });
            $user->save;
        }
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        $token_type = 'oauth_token';
    }

    my $_get_account_details = sub {
        my ($clnt, $curr) = @_;

        my $exclude_until = $clnt->get_self_exclusion_until_date;

        return {
            loginid              => $clnt->loginid,
            currency             => $curr,
            landing_company_name => $clnt->landing_company->short,
            is_disabled          => $clnt->get_status('disabled') ? 1 : 0,
            is_virtual           => $clnt->is_virtual ? 1 : 0,
            $exclude_until ? (excluded_until => Date::Utility->new($exclude_until)->epoch) : ()};
    };

    my $client_list = $user->get_clients_in_sorted_order([keys %{$user->loginid_details}]);

    my @account_list;
    my $currency;
    foreach my $clnt (@$client_list) {
        $currency = $clnt->default_account ? $clnt->default_account->currency_code : '';
        push @account_list, $_get_account_details->($clnt, $currency);
    }

    my $account = $client->default_account;
    return {
        fullname => $client->full_name,
        loginid  => $client->loginid,
        balance  => $account ? formatnumber('amount', $account->currency_code, $account->balance) : '0.00',
        currency => ($account ? $account->currency_code : ''),
        email    => $client->email,
        country  => $client->residence,
        landing_company_name     => $lc->short,
        landing_company_fullname => $lc->name,
        scopes                   => $scopes,
        is_virtual               => $client->is_virtual ? 1 : 0,
        upgradeable_landing_companies => _get_upgradeable_landing_companies($client_list, $client),
        account_list                  => \@account_list,
        stash                         => {
            loginid              => $client->loginid,
            email                => $client->email,
            token                => $token,
            token_type           => $token_type,
            scopes               => $scopes,
            account_id           => ($account ? $account->id : ''),
            country              => $client->residence,
            currency             => ($account ? $account->currency_code : ''),
            landing_company_name => $lc->short,
            is_virtual           => ($client->is_virtual ? 1 : 0),
        },
    };
};

rpc logout => sub {
    my $params = shift;

    if (my $email = $params->{email}) {
        my $token_details = $params->{token_details};
        my ($loginid, $scopes) = ($token_details and exists $token_details->{loginid}) ? @{$token_details}{qw/loginid scopes/} : ();

        if (my $user = BOM::User->new({email => $email})) {
            my $skip_login_history;

            if ($params->{token_type} eq 'oauth_token') {
                # revoke tokens for user per app_id
                my $oauth  = BOM::Database::Model::OAuth->new;
                my $app_id = $oauth->get_app_id_by_token($params->{token});

                # need to skip as we impersonate from backoffice using read only token
                $skip_login_history = 1 if ($scopes and scalar(@$scopes) == 1 and $scopes->[0] eq 'read');

                foreach my $c1 ($user->clients) {
                    $oauth->revoke_tokens_by_loginid_app($c1->loginid, $app_id);
                }

                unless ($skip_login_history) {
                    $user->add_login_history({
                        environment => BOM::RPC::v3::Utility::login_env($params),
                        successful  => 't',
                        action      => 'logout',
                    });
                    $user->save;
                    BOM::User::AuditLog::log("user logout", join(',', $email, $loginid // ''));
                }
            }
        }
    }
    return {status => 1};
};

1;

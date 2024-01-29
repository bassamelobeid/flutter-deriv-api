package BOM::RPC::v3::NewAccount;

use strict;
use warnings;
use Syntax::Keyword::Try;
use List::MoreUtils       qw(any);
use List::Util            qw(minstr);
use Format::Util::Numbers qw/formatnumber/;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
use Log::Any qw($log);
use URI;
use Text::Trim;
use Email::Valid;

use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Config;
use BOM::Database::Model::OAuth;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Locale;
use BOM::Platform::Redis;
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;
use BOM::MyAffiliates;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::User::Client;
use BOM::User::FinancialAssessment qw(update_financial_assessment decode_fa);
use BOM::User;
use BOM::Rules::Engine;
use BOM::Config::AccountType::Registry;
use BOM::RPC::v3::MT5::Account;
use BOM::RPC::v3::Services::CellxpertService;
use BOM::RPC::v3::Services::MyAffiliates;
use BOM::RPC::v3::VerifyEmail::Functions;
use BOM::RPC::v3::Services::MyAffiliates;
use BOM::RPC::v3::Annotations qw(annotate_db_calls);

use constant {
    TOKEN_GENERATION_ATTEMPTS => 5,
    REFRESH_TOKEN_LENGTH      => 29,
    REFRESH_TOKEN_TIMEOUT     => 60 * 60 * 24 * 60,    # 60 days.
    REQUEST_EMAIL_TOKEN_TTL   => 3600
};

requires_auth('trading', 'wallet');

sub _create_oauth_token {
    my ($app_id, $loginid) = @_;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only($app_id, $loginid);
    return $access_token;
}

rpc "verify_email",
    auth => [],    # unauthenticated
    sub {
    my $params              = shift;
    my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(%{$params});

    return $verify_email_object->do_verification();
    };

rpc "verify_email_cellxpert",
    auth => [],    # unauthenticated
    sub {
    my $params = shift;
    $params->{args}->{verify_email} = $params->{args}->{verify_email_cellxpert};
    my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(%{$params});

    return $verify_email_object->do_verification();
    };

sub _update_professional_existing_clients {

    my ($clients, $professional_status, $professional_requested) = @_;

    if ($professional_requested && $clients) {
        foreach my $client (@{$clients}) {
            my $error = BOM::RPC::v3::Utility::set_professional_status($client, $professional_status, $professional_requested);
            return $error if $error;
        }
    }

    return undef;
}

=head2 _get_professional_details_clients

gets the professional requested and status value from clients against svg and malta invest landing company

=over 4

=item * C<args> 

=item * C<$user> 


=back

Returns an array  C<BOM::User::Client>  instance, Professional Status boolean and Professional Requested boolean

=cut

sub _get_professional_details_clients {
    my ($user, $args) = @_;

    # Filter out MF/CR clients
    my @clients = map { $user->clients_for_landing_company($_) } qw/svg maltainvest/;

    # Get the professional flags
    my $professional_status = any { $_->status->professional } @clients;
    my $professional_requested =
        !$professional_status && (($args->{client_type} eq 'professional') || any { $_->status->professional_requested } @clients);

    return (\@clients, $professional_status, $professional_requested);
}

rpc new_account_real => sub {
    my $params = shift;
    my ($client, $args) = @{$params}{qw/client args/};

    $args = BOM::User::Utility::trim_immutable_client_fields($args);

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $company;

    if ($client->is_legacy) {
        # Legacy flow
        $company = $countries_instance->gaming_company_for_country($client->residence)
            || $countries_instance->financial_company_for_country($client->residence);

        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion') if !$company || $company eq 'none';

        # Send error if a maltainvest account  is going to be created here;
        # because they should be created using new_account_maltainvest call
        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount') if $company eq 'maltainvest';

        $args->{account_type} = 'binary';
    } elsif ($client->is_wallet && !$client->is_virtual) {
        #Trading account flow
        $company = $client->landing_company->short;
        $args->{account_type} = 'standard';
    } else {
        # We only allow to create new trading accounts from legacy accounts and from real money wallets accounts.
        # Any other account types are not allowed to use this API call.
        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount');
    }

    my $account_type = BOM::Config::AccountType::Registry->account_type_by_name($args->{account_type})
        or die "Invalid account type $args->{account_type}";

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion')
        unless $account_type->is_supported(request()->brand, $client->residence, $company);

    my $broker = $account_type->get_single_broker_code($company);

    my $response;
    if ($account_type->name eq 'binary') {
        # Legacy trading signup flow
        $response = create_new_real_account(
            client          => $client,
            args            => $args,
            account_type    => $account_type->name,
            category        => $account_type->category->name,
            broker_code     => $broker,
            environment     => request()->login_env($params),
            user_agent      => $params->{user_agent} // '',
            ip              => $params->{client_ip}  // '',
            source          => $params->{source},
            landing_company => $company,
        );
    } elsif ($account_type->name eq 'standard') {
        $args = +{currency => $client->default_account->currency_code};
        # New trading signup flow
        $response = create_trading_account(
            client          => $client,
            args            => $args,
            account_type    => $account_type->name,
            category        => $account_type->category->name,
            broker_code     => $broker,
            environment     => request()->login_env($params),
            user_agent      => $params->{user_agent} // '',
            ip              => $params->{client_ip}  // '',
            source          => $params->{source},
            landing_company => $company,
        );
    } else {
        die 'Unexpected account type ' . $account_type->name;
    }

    return $response if $response->{error};

    my $new_client = $response->{client};

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $new_client->landing_company->name,
        landing_company_shortcode => $new_client->landing_company->short,
        oauth_token               => $response->{oauth_token},
        $args->{currency} ? (currency => $new_client->currency) : (),
    };
};

=head2 new_account_maltainvest

Create a new Maltainvest MF account account

=over 4

=item * C<args> new account details

=back

Returns a C<BOM::User::Client> or C<BOM::User::Wallet> instance

=cut

rpc new_account_maltainvest => annotate_db_calls(
    read  => [],
    write => ['clientdb', 'userdb', 'authdb'],
) => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};
    my $user = $client->user;
    $args = BOM::User::Utility::trim_immutable_client_fields($args);

    # this API call will be depricated and only available for legacy accounts.
    # After upgrading to wallets all trading accounts creation must be done through new_account_real
    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount') unless $client->is_legacy;

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $company = $countries_instance->financial_company_for_country($client->residence) // '';

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount') unless $company;

    # this call is exclusively for maltainvest
    return BOM::RPC::v3::Utility::permission_error if ($company ne 'maltainvest');

    my $account_type = BOM::Config::AccountType::Registry->account_type_by_name($args->{account_type} // 'binary')
        or die "Invalid account type $args->{account_type}";
    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion')
        unless $account_type->is_supported(request()->brand, $client->residence, $company);

    if ($args->{employment_status} && ($args->{employment_status} eq 'Unemployed' || $args->{employment_status} eq 'Self-Employed')) {
        $args->{employment_industry} //= 'Unemployed';
        $args->{occupation}          //= 'Unemployed';
    }

    my $broker = $account_type->get_single_broker_code($company);

    my $response = create_new_real_account(
        client          => $client,
        args            => $args,
        account_type    => $account_type->name,
        category        => $account_type->category->name,
        broker_code     => $broker,
        market_type     => 'financial',
        environment     => request()->login_env($params),
        ip              => $params->{client_ip} // '',
        source          => $params->{source},
        landing_company => 'maltainvest',
    );
    return $response if $response->{error};

    my $new_client = $response->{client};

    # Client's citizenship can only be set from backoffice.
    # However, when a Deriv Investments (Europe) Limited account is created, the citizenship
    # is not updated in the new account.
    # Hence, the following check is necessary
    $new_client->citizen($client->citizen) if ($client->citizen && !$client->is_virtual);
    # Save new account
    if (not $new_client->save) {
        stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:new_account_maltainvest"]});
        return BOM::RPC::v3::Utility::client_error();

    }
    # In case of having more than a tax residence, client residence will replaced.
    my $selected_tax_residence    = $args->{tax_residence} =~ /\,/g ? $args->{residence} : $args->{tax_residence};
    my $tin_format                = $countries_instance->get_tin_format($selected_tax_residence);
    my $tax_identification_number = $args->{tax_identification_number} // '';
    if ($tin_format) {
        stats_inc('bom_rpc.v_3.new_account_maltainvest.called_with_wrong_TIN_format.count')
            unless (any { $tax_identification_number =~ m/$_/ } @$tin_format);
    }

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $new_client->landing_company->name,
        landing_company_shortcode => $new_client->landing_company->short,
        oauth_token               => $response->{oauth_token},
    };
};

rpc "new_account_virtual",
    auth => [],
    sub {
    my $params = shift;
    my $args   = $params->{args};

    $args->{token_details} = delete $params->{token_details};

    my $category = delete $args->{type} // 'trading';

    #TODO: At some point in time instead of binary here should be standard...
    # We need to define conditions when we stop creating legacy accounts
    # Maybe check if virtual wallet already created?
    my $account_type_name = $args->{account_type} // ($category eq 'trading' ? 'binary' : 'virtual');
    my $account_type      = BOM::Config::AccountType::Registry->account_type_by_name($account_type_name);
    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion')
        unless $account_type && $account_type->is_regulation_supported('virtual');

    my $broker = $account_type->get_single_broker_code('virtual');
    $args->{broker} = $broker;

    return BOM::RPC::v3::Utility::suspended_login()
        if grep { $broker eq $_ } BOM::Config::Runtime->instance->app_config->system->suspend->logins->@*;

    if ($category eq 'wallet' && BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize("Wallet account creation is currently suspended."),
        });
    }

    if ($args->{token_details} and not $args->{verification_code}) {
        my $scopes = $args->{token_details}->{scopes};
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize("The token is invalid, requires 'admin' scope.")}) unless (any { $_ eq 'admin' } @$scopes);
    }

    my ($client, $account);
    try {
        $args->{ip}           = $params->{client_ip}  // '';
        $args->{user_agent}   = $params->{user_agent} // '';
        $args->{country}      = uc($params->{country_code} // '');
        $args->{environment}  = request()->login_env($params);
        $args->{source}       = $params->{source};
        $args->{account_type} = $account_type->name;
        $args->{category}     = $account_type->category->name;

        # Pre-set email if client is authorized
        if ($args->{token_details}) {
            my $user = BOM::User->new(loginid => $args->{token_details}->{loginid});
            $args->{email} = $user->{email};
        }

        $client  = create_virtual_account($args);
        $account = $client->default_account;

        my $oauth_model = BOM::Database::Model::OAuth->new;
        my $refresh_token;

        # this is the first account of the user
        if (scalar $client->user->clients == 1) {
            $refresh_token = $oauth_model->generate_refresh_token($client->binary_user_id, $params->{source});
        }

        return {
            client_id   => $client->loginid,
            email       => $client->email,
            currency    => $account->currency_code(),
            balance     => formatnumber('amount', $account->currency_code(), $account->balance),
            oauth_token => _create_oauth_token($params->{source}, $client->loginid),
            type        => $category,
            $refresh_token ? (refresh_token => $refresh_token) : (),
        };
    } catch ($e) {
        my $error_map = BOM::RPC::v3::Utility::error_map();
        my $error->{code} = $e;
        $error = $e->{error} // $e if (ref $e eq 'HASH');
        $error->{message_to_client} = $error->{message_to_client} // $error_map->{$error->{code}};

        return BOM::RPC::v3::Utility::client_error() unless ($error->{message_to_client});

        return BOM::RPC::v3::Utility::create_error({
                code              => $error->{code},
                message_to_client => $error->{message_to_client},
                details           => $error->{details}});
    };
    };

rpc new_account_wallet => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};
    $args = BOM::User::Utility::trim_immutable_client_fields($args);

    if (BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize("Wallet account creation is currently suspended."),
        });
    }

    $args->{residence} //= $client->residence;

    my $company_name = $args->{landing_company_short} // 'svg';

    if (exists $args->{financial_assessment}) {
        $args = {%{$args}, %{$args->{financial_assessment}}};
        delete $args->{financial_assessment};
    }

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $is_maltainvest = $company_name eq 'maltainvest';

    my $currency_type = LandingCompany::Registry::get_currency_type($args->{currency} // '');
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidRequestParams',
            message_to_client => localize('Invalid request parameters.'),
            details           => {field => 'currency'}}) unless $currency_type;

    my $account_type = $args->{account_type} && BOM::Config::AccountType::Registry->account_type_by_name($args->{account_type});

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidRequestParams',
            message_to_client => localize('Invalid request parameters.'),
            details           => {field => 'account_type'}}) unless $account_type && $account_type->category->name eq 'wallet';

    my $wallet_lc = LandingCompany::Registry->by_name($company_name // '');

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion')
        unless $wallet_lc && $account_type->is_supported(request()->brand, $client->residence, $company_name);

    my $broker = $account_type->get_single_broker_code($company_name);

    my $response = create_new_real_account(
        client          => $client,
        args            => $args,
        account_type    => $account_type->name,
        category        => $account_type->category->name,
        broker_code     => $broker,
        landing_company => $company_name,
        environment     => request()->login_env($params),
        ip              => $params->{client_ip} // '',
        source          => $params->{source},
    );
    return $response if $response->{error};

    my $new_client      = $response->{client};
    my $landing_company = $new_client->landing_company;

    if ($is_maltainvest) {
        # Client's citizenship can only be set from backoffice.
        # However, when a Deriv Investments (Europe) Limited account is created, the citizenship
        # is not updated in the new account.
        # Hence, the following check is necessary
        $new_client->citizen($client->citizen) if ($client->citizen && !$client->is_virtual);
        # Save new account
        if (not $new_client->save) {
            stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:new_account_maltainvest"]});
            return BOM::RPC::v3::Utility::client_error();
        }

        # In case of having more than a tax residence, client residence will replaced.
        my $selected_tax_residence = $args->{tax_residence} =~ /\,/g ? $args->{residence} : $args->{tax_residence};
        my $tin_format             = $countries_instance->get_tin_format($selected_tax_residence);
        my $client_tin             = $countries_instance->clean_tin_format($args->{tax_identification_number}, $selected_tax_residence);
        if ($tin_format) {
            stats_inc('bom_rpc.v_3.new_account_maltainvest.called_with_wrong_TIN_format.count')
                unless (any { $client_tin =~ m/$_/ } @$tin_format);
        }
    }

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
        currency                  => $new_client->currency,
    };
};

=head2 create_virtual_account

Create a new virtual wallet or trading account

=over 4

=item * C<args> new account details

=back

Returns a C<BOM::User::Client> or C<BOM::User::Wallet> instance

=cut

sub create_virtual_account {
    my ($args) = @_;

    # Non-PEP declaration is not made for virtual accounts
    delete $args->{non_pep_declaration};

    my $is_affiliate = ($args->{account_opening_reason} // '' eq 'affiliate') ? 1 : 0;
    my ($error);

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->check_for_update();
    my $is_email_verification_suspended = $app_config->email_verification->suspend->virtual_accounts;

    if ($args->{token_details} and not $args->{verification_code}) {
        # To create a second virtual account, check for token; password is redundant
        for my $field (qw( client_password )) {
            die +{
                code              => 'InvalidRequestParams',
                message_to_client => localize('Invalid request parameters.'),
                details           => {field => $field}}
                if ($args->{$field});
        }
        my $user = BOM::User->new(loginid => $args->{token_details}->{loginid});
        $args->{email} = $user->{email};
        # get residence from an existing client
        $args->{residence} = $user->get_default_client->residence;
    } else {
        # To create a new user, check for client_password, residence and verification_code
        # For signup without email verification, check for client_password, residence and email
        # These required fields were excluded from JSON schema, we need to handle it here
        my @required_fields = ('client_password', 'residence', ($is_email_verification_suspended ? 'email' : 'verification_code'));

        for my $field (@required_fields) {
            next if $args->{$field};
            die +{
                code    => 'InputValidationFailed',
                details => {field => $field}};
        }

        my $verification_code = $args->{verification_code};
        $args->{email} = BOM::Platform::Token->new({token => $verification_code})->email unless ($is_email_verification_suspended || $args->{email});

        $args->{account_created_for} //= 'account_opening';
        $error =
            BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $args->{email}, $args->{account_created_for}, $is_affiliate)
            ->{error}
            unless $is_email_verification_suspended;
        die $error if $error;

        die +{code => 'InvalidEmail'}
            if ($is_email_verification_suspended && !Email::Valid->address($args->{email}));

        $error = BOM::RPC::v3::Utility::check_password({
                email        => $args->{email},
                new_password => $args->{client_password}});
        die $error if $error;
    }
    if ($args->{category} eq 'wallet') {
        my $countries_instance = request()->brand->countries_instance;
        my $allowed_companies  = $countries_instance->wallet_companies_for_country($args->{residence}, 'virtual') // [];

        die BOM::RPC::v3::Utility::create_error_by_code('invalid residence')
            unless any { $_ eq "virtual" } $allowed_companies->@*;
    }
    # Create account
    my $account_args = {
        ip      => $args->{id},
        country => $args->{country},
        details => {
            email           => $args->{email},
            email_consent   => $args->{email_consent},
            client_password => $args->{client_password},
            residence       => $args->{residence},
            source          => $args->{source},
            account_type    => $args->{account_type},
            email_verified  => $is_email_verification_suspended ? 0 : 1,
        },
        utm_data               => {},
        account_opening_reason => $args->{account_opening_reason} // '',
    };

    # Clients from Spain and portugal are not allowed to signup via affiliate links hence we are removing their token.
    if ($args->{affiliate_token} && (lc($args->{residence}) eq 'pt' || lc($args->{residence}) eq 'es')) {
        $args->{affiliate_token} = "";
    }

    $account_args->{details}->{myaffiliates_token} = $args->{affiliate_token} if $args->{affiliate_token};

    my $regex_validation = {qr{^utm_.+} => qr{^[\w\s\.\-_]{1,100}$}};
    my @tags_list        = qw(date_first_contact gclid_url signup_device utm_campaign utm_medium utm_source);

    my $filtered_url_parameters = BOM::Platform::Utility::extract_valid_params(\@tags_list, $args, $regex_validation);
    foreach my $k (keys $filtered_url_parameters->%*) {
        $account_args->{details}->{$k} = $args->{$k} if $args->{$k};
    }

    @tags_list = qw(
        utm_ad_id        utm_adgroup_id utm_adrollclk_id utm_campaign_id utm_content utm_fbcl_id
        utm_gl_client_id utm_msclk_id   utm_term
    );

    $filtered_url_parameters = BOM::Platform::Utility::extract_valid_params(\@tags_list, $args, $regex_validation);
    foreach my $k (keys $filtered_url_parameters->%*) {
        $account_args->{utm_data}->{$k} = $args->{$k} if $args->{$k};
    }

    my $account = BOM::Platform::Account::Virtual::create_account($account_args);
    die $account->{error} if $account->{error};

    # Check if it is from UK, instantly mark it as unwelcome
    my $config = request()->brand->countries_instance->countries_list->{$account->{client}->residence};
    if ($config->{virtual_age_verification}) {
        $account->{client}->status->set('unwelcome', 'SYSTEM', 'Pending proof of age');
    }

    my $user = $account->{user};
    $user->add_login_history(
        action      => 'login',
        environment => $args->{environment},
        successful  => 't',
        app_id      => $args->{source});

    BOM::User::AuditLog::log("successful login", "$args->{email}");

    my $client = $account->{client};
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'virtual',
        currency      => $client->currency,
        loginid       => $client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    my $utm_tags = {};
    @tags_list = qw(date_first_contact gclid_url signup_device utm_campaign utm_content utm_medium utm_source utm_term);
    foreach my $tag (@tags_list) {
        $utm_tags->{$tag} = $args->{$tag} if $args->{$tag};
    }

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $client->loginid,
            properties => {
                type       => $args->{account_type} eq 'binary' ? 'trading' : 'wallet',
                subtype    => 'virtual',
                user_agent => $args->{user_agent} // '',
                utm_tags   => BOM::Platform::Utility::extract_valid_params(\@tags_list, $utm_tags, $regex_validation)}});

    return $client;
}

=head2 create_new_real_account_for_affiliate

Creates a new real account for affiliate.

=over 4

=item * C<client> form client which the new real account is being created

=item * C<args> new account request arguments

=back

Returns a C<BOM::User::Client> instance

=cut

sub create_new_real_account_for_affiliate {
    my %params = @_;
    my $client = $params{client};
    my $args   = $params{args};

    $args->{$_} = $params{$_} for (qw/broker_code account_type market_type source landing_company environment/);
    my $details_ref = _new_account_pre_process($args, $client);
    my $error_map   = BOM::RPC::v3::Utility::error_map();
    if ($details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $details_ref->{message_to_client} // $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }

    my $user = $client->user;
    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);
    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);
    return $val if $val;

    my $lock = BOM::Platform::Redis::acquire_lock($client->user_id, 10);
    return BOM::RPC::v3::Utility::rate_limit_error() if not $lock;

    my $create_account_sub =
        $params{landing_company} eq 'maltainvest'
        ? \&BOM::Platform::Account::Real::maltainvest::create_account
        : \&BOM::Platform::Account::Real::default::create_account;

    # It's safe to create the new client now
    my $acc;
    try {
        $acc = $create_account_sub->({
            ip          => $params{ip} // '',
            country     => uc($client->residence // ''),
            from_client => $client,
            user        => $user,
            details     => $details_ref->{details},
            params      => $args,
        });
    } finally {
        BOM::Platform::Redis::release_lock($client->user_id);
    }

    my $error;
    if ($error = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $error,
                message_to_client => $error_map->{$error}});
    }

    my $new_client = $acc->{client};

    _new_account_post_process(
        client                 => $client,
        new_client             => $new_client,
        args                   => $args,
        professional_status    => $professional_status,
        professional_requested => $professional_requested
    );

    return {
        client      => $new_client,
        oauth_token => _create_oauth_token($params{source}, $new_client->loginid),
    };
}

=head2 create_new_real_account

Creates a new real account. It's called by all real account opening RPC handlers.

=over 4

=item * C<client> form client which the new real account is being created

=item * C<args> new account request arguments

=back

Returns a C<BOM::User::Client> instance

=cut

sub create_new_real_account {
    my %params = @_;
    my $client = $params{client};
    my $args   = $params{args};

    $args->{$_} = $params{$_} for (qw/broker_code account_type market_type source landing_company user_agent environment category/);

    my $details_ref = _new_account_pre_process($args, $client);
    my $error_map   = BOM::RPC::v3::Utility::error_map();
    if ($details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $details_ref->{message_to_client} // $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }

    my $user = $client->user;
    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);
    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);
    return $val if $val;
    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my $action      = $args->{category} eq 'wallet' ? 'new_wallet' : 'new_account';
    try {
        # Rules are applied on actual request arguments ($args),
        # not the initialized values ($details_ref->{details}) used for creating the client object.
        $rule_engine->verify_action(
            $action,
            %$args,
            action_type     => 'create',
            loginid         => $client->loginid,
            landing_company => $params{landing_company},
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    };
    my $lock = BOM::Platform::Redis::acquire_lock($client->user_id, 10);
    return BOM::RPC::v3::Utility::rate_limit_error() if not $lock;
    my $create_account_sub =
        $params{landing_company} eq 'maltainvest'
        ? \&BOM::Platform::Account::Real::maltainvest::create_account
        : \&BOM::Platform::Account::Real::default::create_account;
    # It's safe to create the new client now
    my $acc;
    try {
        $acc = $create_account_sub->({
            ip           => $params{ip} // '',
            country      => uc($client->residence // ''),
            from_client  => $client,
            user         => $user,
            details      => $details_ref->{details},
            params       => $args,
            account_type => delete $args->{account_type},
        });
    } finally {
        BOM::Platform::Redis::release_lock($client->user_id);
    }

    my $error;
    if ($error = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $error,
                message_to_client => $error_map->{$error}});
    }

    my $new_client = $acc->{client};
    _new_account_post_process(
        client                 => $client,
        new_client             => $new_client,
        args                   => $args,
        professional_status    => $professional_status,
        professional_requested => $professional_requested
    );
    return {
        client      => $new_client,
        oauth_token => _create_oauth_token($params{source}, $new_client->loginid),
    };

}

=head2 create_trading_account

Creates trading account 

=cut

sub create_trading_account {
    my %params = @_;
    my $client = $params{client};
    my $args   = $params{args};

    $args->{$_} = $params{$_} for (qw/broker_code account_type market_type source landing_company environment category user_agent/);
    my $details_ref = _new_account_pre_process($args, $client);
    my $error_map   = BOM::RPC::v3::Utility::error_map();
    if ($details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $details_ref->{message_to_client} // $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }

    my $user = $client->user;
    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);
    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);
    return $val if $val;

    if ($client->financial_assessment()) {
        my $financial_assessment = decode_fa($client->financial_assessment());
        $args = +{$args->%*, $financial_assessment->%*};
    }

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        # Rules are applied on actual request arguments ($args),
        # not the initialized values ($details_ref->{details}) used for creating the client object.
        $rule_engine->verify_action(
            'new_account',
            %$args,
            action_type     => 'create',
            loginid         => $client->loginid,
            landing_company => $params{landing_company},
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    };

    my $lock = BOM::Platform::Redis::acquire_lock($client->user_id, 10);
    return BOM::RPC::v3::Utility::rate_limit_error() if not $lock;

    my $create_account_sub =
        $params{landing_company} eq 'maltainvest'
        ? \&BOM::Platform::Account::Real::maltainvest::create_account
        : \&BOM::Platform::Account::Real::default::create_account;

    # It's safe to create the new client now
    my $acc;
    try {
        $acc = $create_account_sub->({
            ip           => $params{ip} // '',
            country      => uc($client->residence // ''),
            from_client  => $client,
            user         => $user,
            details      => $details_ref->{details},
            params       => $args,
            account_type => delete $args->{account_type},
            wallet       => $client
        });
    } finally {
        BOM::Platform::Redis::release_lock($client->user_id);
    }

    my $error;
    if ($error = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $error,
                message_to_client => $error_map->{$error}});
    }

    my $new_client = $acc->{client};

    _new_account_post_process(
        client                 => $client,
        new_client             => $new_client,
        args                   => $args,
        professional_status    => $professional_status,
        professional_requested => $professional_requested,
    );

    return {
        client      => $new_client,
        oauth_token => _create_oauth_token($params{source}, $new_client->loginid),
    };
}

=head2 _new_account_pre_process

Validates and initilizes account details on real account opening, taking following arguments:

=over 4

=item * C<args> - RPC call arguments

=item * C<client> - The client who is requesting for account opening

=item * C<broker> - broker code of the new account

=item * C<source> - the source app id

=back

Returns {
    error   => C<error_code>
    details => C<detail info>
}

=cut

sub _new_account_pre_process {
    my ($args, $client) = @_;

    $client = (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0] // $client
        if $client->is_virtual;

    # has remianed from the history of design
    $args->{client_type} //= 'retail';

    my $broker       = $args->{broker_code};
    my $account_type = $args->{account_type};

    return BOM::RPC::v3::Utility::suspended_login()
        if grep { $broker eq $_ } BOM::Config::Runtime->instance->app_config->system->suspend->logins->@*;

    if (BOM::Config::Runtime->instance->app_config->system->suspend->new_accounts) {
        my $loginid   = $client->loginid;
        my $residence = $client->residence;
        warn "acc opening err: from_loginid:$loginid, account_type:$account_type, residence:$residence, error: - new account opening suspended";
        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount');
    }

    return BOM::RPC::v3::Utility::create_error_by_code('NoResidence') unless $client->residence;

    unless ($client->is_virtual) {
        # Lets populate all sensitive data from current client, ignoring provided input
        # this logic should gone after we separate new_account with new_currency for account
        foreach (qw/first_name last_name residence address_city phone date_of_birth address_line_1 citizen place_of_birth/) {
            $args->{$_} = $client->$_ if $client->$_;
        }
    }

    my $non_pep_declaration = delete $args->{non_pep_declaration};
    $args->{non_pep_declaration_time} = _get_non_pep_declaration_time($client, $args->{landing_company}, $non_pep_declaration, $args->{source});

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        latest_environment            => '',
        source                        => $args->{source},
    };

    $details->{myaffiliates_token} = _compute_affiliate_token($client, $args);

    delete $args->{affiliate_token} if (exists $args->{affiliate_token});

    my @fields_to_duplicate =
        qw(citizen salutation first_name last_name date_of_birth residence address_line_1 address_line_2 address_city address_state address_postcode phone secret_question secret_answer place_of_birth tax_residence tax_identification_number account_opening_reason);

    # copy data from the duplicate sibling if any
    my $duplicated = $client->duplicate_sibling_from_vr;

    $client = $duplicated if $duplicated;

    unless ($client->is_virtual) {
        for my $field (@fields_to_duplicate) {
            if ($field eq "secret_answer") {
                $args->{$field} ||= BOM::User::Utility::decrypt_secret_answer($client->$field);
            } else {
                $args->{$field} ||= $client->$field;
            }
        }
    }

    my $error = $client->format_input_details($args);
    return $error if $error;

    $args->{secret_answer} = BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) if $args->{secret_answer};

    # This exist to accommodate some rules in our database (mostly NOT NULL and NULL constraints). Should change to be more consistent. Also used to filter the args to return for new account creation.
    my %default_values = (
        citizen                   => '',
        salutation                => '',
        first_name                => '',
        last_name                 => '',
        date_of_birth             => undef,
        residence                 => '',
        address_line_1            => '',
        address_line_2            => '',
        address_city              => '',
        address_state             => '',
        address_postcode          => '',
        phone                     => '',
        secret_question           => '',
        secret_answer             => '',
        tax_residence             => '',
        tax_identification_number => '',
        account_opening_reason    => '',
        place_of_birth            => undef,
        tax_residence             => undef,
        tax_identification_number => undef,
        non_pep_declaration_time  => undef,
        currency                  => undef,
        account_type              => undef,
    );

    for my $field (keys %default_values) {
        $details->{$field} = $args->{$field} // $default_values{$field};
    }
    $details->{account_type} = $account_type;

    return {details => $details};
}

=head2 _new_account_post_process

Validates and initilizes account details on real account opening, taking following arguments:

=over 4

=item * C<args> - RPC call arguments

=item * C<client> - The client who is requesting for account opening

=item * C<broker> - broker code of the new account

=item * C<source> - the source app id

=back

Returns {
    error   => C<error_code>

    details => C<detail info>
}

=cut

sub _new_account_post_process {
    my %par = @_;

    my ($client, $new_client, $args, $professional_status, $professional_requested) =
        @par{qw/client new_client args professional_status  professional_requested/};

    # Ported from previous implementations of new_account_real, new_account_maltainvest  and new_wallet_real RPC codes
    my $error;

    # Set affiliate data if required
    if ($new_client->landing_company->is_for_affiliates) {
        $new_client->set_affiliate_info({affiliate_plan => $args->{affiliate_plan}});
    }

    if (any { $new_client->{account_type} eq $_ } qw/binary standard affiliate/) {

        # TODO: keep it as is for now, but FA sync probably should be done within single landing compamy
        # based on current logic it's done across all client accounts
        update_financial_assessment($client->user, decode_fa($client->financial_assessment()))
            if $client->financial_assessment() && $new_client->landing_company->short eq 'svg';

        # XXX If we fail after account creation then we could end up with these flags not set,
        # ideally should be handled in a single transaction
        # as account is already created so no need to die on status set
        # else it will give false impression to client
        $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);
        return $error if $error;

        my $config = request()->brand->countries_instance->countries_list->{$new_client->residence};
        if (   $config->{need_set_max_turnover_limit}
            or $new_client->landing_company->check_max_turnover_limit_is_set)
        {    # RTS 12 - Financial Limits - UK Clients and MLT Clients
            try { $new_client->status->set('max_turnover_limit_not_set', 'system', 'new GB client or MLT client - have to set turnover limit') }
            catch { return BOM::RPC::v3::Utility::client_error() }
        }
    }
    try {
        $new_client->sync_authentication_from_siblings;
    } catch ($error) {
        $log->errorf('Failed to sync authentication for client %s: %s', $new_client->loginid, $error);
        return BOM::RPC::v3::Utility::client_error()
    };

    # Not sure if the following notfications are required for wallet creation or not
    $client->user->add_login_history(
        action      => 'login',
        environment => $args->{environment},
        successful  => 't',
        app_id      => $args->{source});

    BOM::User::AuditLog::log("successful login", "$client->email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'real',
        currency      => $args->{currency} // 'USD',
        loginid       => $new_client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $new_client->loginid,
            properties => {
                # TODO: CHECK PROPERTIES AGAINST EVENT HANDLER
                type => $new_client->get_account_type->category
                    ->name,    #keep it for backward compatibility, Before removing please check bom-events and cio

                account_type => $new_client->get_account_type->name,
                category     => $new_client->get_account_type->category->name,
                subtype      => 'real',
                user_agent   => $args->{user_agent},
            }});
}

=head2 _get_non_pep_declaration_time

Called on new real account rpc calls, it returns the time clients have submitted their (non-)PEP declartion for a landing company.
If there is an older account in the same landing company, it's declaration time will be returned.
If there is not any non-PEP declaration found for the specified landing company, current time will be returned.

#TODO(Mat): If all apps (both official and third-party) send non_pep_declaration whenever it's submitted by clients on signup,
#    the return value should be changed to undef if non-PEP declaration was missing.

=over 4

=item * C<client> - current client who has initated a new real account request

=item * C<company> - landing company of the new account being created

=item * C<non_pep_declaration> - boolean value that determines if non-PEP declaration is made through the current signup process

=item * C<app_id> - the id of the app through which the request is made

=back

returns the time when the client has declared they are not a PEP/RCA for the requested C<company>.

=cut

sub _get_non_pep_declaration_time {
    my ($client, $company, $non_pep_declaration) = @_;

    return time if $non_pep_declaration;

    # declaration time can be safely extracted from older siblings in the same landing company.
    my @same_lc_siblings = $client->user->clients_for_landing_company($company);

    for (@same_lc_siblings) {
        return $_->non_pep_declaration_time if $_->non_pep_declaration_time;
    }

    #TODO(Mat): we will return undef here, provided that nothing is logged by the above line
    #           (non_pep_declaration is sent from all appls for the first real account per landing complany).
    return minstr(map { $_->date_joined } @same_lc_siblings) || time;
}

=head2 affiliate_add_person

Creates a new individual affiliate client account.

Will do:

=over 4

=item - The Affiliate account (new broker code)

=item - Create an MT5 real gaming account

=item - Add a new account in Affiliate System

=back

Will return the following data:

=over 4

=item - C<client_id> the new client loginid

=item - C<landing_company>

=item - C<landing_company_shortcode>

=item - C<Affiliate User ID>

=back

=cut

rpc "affiliate_add_person",
    auth => [],
    sub {
    my $params = shift;

    $params->{third_party_function} = \&BOM::RPC::v3::Services::MyAffiliates::affiliate_add_person;
    return _do_affiliate($params);
    };

=head2 affiliate_add_company

Creates a new company affiliate client account.
Will do:

=over 4

=item - The Affiliate account (new broker code)

=item - Create an MT5 real gaming account

=item - Add a new account in Affiliate System

=back

Will return the following data:

=over 4

=item - C<client_id> the new client loginid

=item - C<landing_company>

=item - C<landing_company_shortcode>

=item - C<Affiliate User ID>

=back

=cut

rpc "affiliate_add_company",
    auth => [],
    sub {
    my $params = shift;

    $params->{third_party_function} = \&BOM::RPC::v3::Services::CellxpertService::affiliate_add_company;
    return _do_affiliate($params);
    };

=head2 _compute_affiliate_token

=head3 Parameters:

=over 2

=item * C<client> - The client who is requesting for account opening

=item * C<args> - RPC call arguments

=back

=head3 Return:

=over 1

=item * C<affiliate_token> the affliate token

=back

=pod

B<Uses Cases:>

1. User creates first account with affiliate ==> add affiliate s

2. User creates second account with affiliate ==> do not add affliate token ( this user belongs to deriv)

3. User creates second account without affiliate token but other siblings already have token ==> use current token

=cut

sub _compute_affiliate_token {

    my ($client, $args) = @_;
    my $affiliate_token = $args->{affiliate_token} || '';
    my $user            = $client->user;
    my @clients         = $user->clients;
    if (@clients > 0) {
        @clients         = sort { $a->date_joined cmp $b->date_joined } @clients;
        $affiliate_token = $clients[0]->myaffiliates_token || $affiliate_token;
    }

    return $affiliate_token;
}

=head2 _do_affiliate

Will do: 

1- Create ThirdParty affiliate account (via API)

2- Create Demo Account in Deriv

3- Create Real Account in Deriv

=over 4

=item - The Affiliate account (new broker code)

=item - Create an MT5 real gaming account

=item - Add a new account in Affiliate System

=back

Will return the following data:

=over 4

=item - C<client_id> the new client loginid

=item - C<landing_company>

=item - C<landing_company_shortcode>

=item - C<Affiliate User ID>

=back

=cut

sub _do_affiliate {
    my $params   = shift;
    my $args     = $params->{args};
    my $broker   = 'CRA';
    my $response = {};

    my $verification_token = BOM::Platform::Token->new({token => $args->{verification_code}});
    my $email              = $verification_token->email;
    unless ($email) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'TokenError',
            message_to_client => 'Can not get email from token',
        });
    }

    my $cx_response = $params->{third_party_function}->($email, $args);

    if ($cx_response->{code} eq "MYAFFRuntimeError") {
        return BOM::RPC::v3::Utility::create_error($cx_response);
    }

    $args->{token_details} = delete $params->{token_details};
    my $category          = 'wallet';
    my $account_type_name = 'affiliate';
    $args->{address_line_1} = $args->{address_street};
    $args->{token_details}  = delete $params->{token_details};
    $args->{type} //= 'trading';    # affiliate demo account will always be trading if not specified.

    if (BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize("Wallet account creation is currently suspended."),
        });
    }

    if ($args->{token_details} and not $args->{verification_code}) {
        my $scopes = $args->{token_details}->{scopes};
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize("The token is invalid, requires 'admin' scope.")}) unless (any { $_ eq 'admin' } @$scopes);
    }

    my ($client, $account);
    try {
        $args->{ip}                  = $params->{client_ip} // '';
        $args->{environment}         = request()->login_env($params);
        $args->{source}              = $params->{source};
        $args->{client_password}     = $args->{password};
        $args->{residence}           = $args->{country};
        $args->{account_created_for} = "partner_account_opening";

        # Todo: This fields are temprary set and should get from future FE forms that not yet implemented
        $args->{affiliate_plan}            = "turnover";
        $args->{accept_risk}               = 1;
        $args->{source_of_wealth}          = "trading";
        $args->{salutation}                = "Mrs";
        $args->{citizen}                   = $args->{country};
        $args->{tax_residence}             = $args->{country};
        $args->{tax_identification_number} = "111-222-333";
        $args->{account_opening_reason}    = "affiliate";
        $args->{payment_method}            = "bank_transfer";
        $args->{account_type}              = 'binary';
        $args->{category}                  = 'trading';

        # Pre-set email if client is authorized
        my $user = BOM::User->new(email => $email);
        if ($user) {
            $client = BOM::User::Client::get_instance({'loginid' => $user->bom_virtual_loginid});
        } else {
            $client = create_virtual_account($args);
        }

        $account = $client->default_account;

        my $oauth_model = BOM::Database::Model::OAuth->new;
        my $refresh_token;

        # this is the first account of the user
        if (scalar $client->user->clients == 1) {
            $refresh_token = $oauth_model->generate_refresh_token($client->binary_user_id, $params->{source});
        }

        $response->{demo} = {
            client_id   => $client->loginid,
            email       => $client->email,
            currency    => $account->currency_code(),
            balance     => formatnumber('amount', $account->currency_code(), $account->balance),
            oauth_token => _create_oauth_token($params->{source}, $client->loginid),
            type        => $args->{type},
            $refresh_token ? (refresh_token => $refresh_token) : (),
        };
    } catch ($e) {
        my $error_map = BOM::RPC::v3::Utility::error_map();
        my $error->{code} = $e;
        $error = $e->{error} // $e if (ref $e eq 'HASH');
        $error->{message_to_client} = $error->{message_to_client} // $error_map->{$error->{code}};
        return BOM::RPC::v3::Utility::client_error() unless ($error->{message_to_client});
        return BOM::RPC::v3::Utility::create_error({
                code              => $error->{code},
                message_to_client => $error->{message_to_client},
                details           => $error->{details}});
    };

    # now we can start creating real account in CRA
    # TODO: check client residence country for EU/UK

    try {
        my $result = create_new_real_account_for_affiliate(
            client          => $client,
            args            => $args,
            account_type    => $account_type_name,
            category        => $category,
            broker_code     => $broker,
            market_type     => 'affiliate',
            environment     => request()->login_env($params),
            ip              => $params->{client_ip} // '',
            source          => $params->{source},
            landing_company => $params->{landing_company} // 'svg'
        );
        return $result if exists $result->{error};

        my $new_client = $result->{client};

        my $res = BOM::RPC::v3::Accounts::api_token({
                client => $new_client,
                args   => {
                    new_token        => 'CRA Token',
                    new_token_scopes => ['read', 'trade', 'payments', 'admin']
                },
            });
        my $cra_token = $res->{tokens}->[0]->{token};

        $response->{real} = {
            client_id                 => $new_client->loginid,
            landing_company           => $new_client->landing_company->name  // '',
            landing_company_shortcode => $new_client->landing_company->short // '',
            oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
            cra_token                 => $cra_token,
            $args->{currency} ? (currency => $new_client->currency) : (),
        };
    } catch ($e) {
        my $error_map = BOM::RPC::v3::Utility::error_map();
        my $error->{code} = $e;
        $error = $e->{error} // $e if (ref $e eq 'HASH');
        $error->{message_to_client} = $error->{message_to_client} // $error_map->{$error->{code}};
        return BOM::RPC::v3::Utility::client_error() unless ($error->{message_to_client});
        return BOM::RPC::v3::Utility::create_error({
                code              => $error->{code},
                message_to_client => $error->{message_to_client},
                details           => $error->{details}});
    }

    $verification_token->delete_token;
    return $response;
}

=head2 affiliate_register_person

Collects affiliate data from our affiliate register form and 
call the myAffiliate register partner Api.

=over 4

=item - Add a new account in Affiliate System

=back

=cut

rpc "affiliate_register_person",
    auth => [],
    sub {

    my $params = shift;
    my $args   = $params->{args};

    my $response = {};

    $params->{third_party_function} = \&BOM::RPC::v3::Services::MyAffiliates::affiliate_add_person;

    try {
        my $myAff_response = $params->{third_party_function}->($args->{email}, $args);

        if ($myAff_response->{code} eq 'MYAFFRuntimeError') {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 400,
                    message_to_client => $myAff_response->{message_to_client}});
        }
        $response = {success => 1};

    } catch ($e) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 500,
            message_to_client => $e
        });
    }

    return $response;

    };

1;

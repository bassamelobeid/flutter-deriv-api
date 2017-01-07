package BOM::RPC::v3::Accounts;

use 5.014;
use strict;
use warnings;

use JSON;
use Try::Tiny;
use WWW::OneAll;
use Date::Utility;
use Data::Password::Meter;
use HTML::Entities qw(encode_entities);
use Brands;
use Client::Account;
use LandingCompany::Registry;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::Japan::NewAccount;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale;
use BOM::Platform::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Token;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( simple_contract_info );
use BOM::System::Config;
use BOM::System::Password;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Model::AccessToken;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::Model::OAuth;
use BOM::Database::Model::UserConnect;

sub payout_currencies {
    my $params = shift;

    my $token_details = $params->{token_details};
    my $client;
    if ($token_details and exists $token_details->{loginid}) {
        $client = Client::Account->new({loginid => $token_details->{loginid}});
    }

    # if client has default_account he had already choosed his currency..
    return [$client->currency] if $client && $client->default_account;

    # or if client has not yet selected currency - we will use list from his LC
    # or we may have a landing company even if we're not logged in - typically this
    # is obtained from the GeoIP country code lookup. If we have one, use it.
    my $lc = $client ? $client->landing_company : LandingCompany::Registry::get($params->{landing_company_name} || 'costarica');
    # ... but we fall back to Costa Rica as a useful default, since it has most
    # currencies enabled.
    $lc ||= LandingCompany::Registry::get('costarica');

    return $lc->legal_allowed_currencies;
}

sub landing_company {
    my $params = shift;

    my $country  = $params->{args}->{landing_company};
    my $configs  = Brands->new(name => request()->brand)->countries_instance->countries_list;
    my $c_config = $configs->{$country};
    unless ($c_config) {
        ($c_config) = grep { $configs->{$_}->{name} eq $country and $country = $_ } keys %$configs;
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnknownLandingCompany',
            message_to_client => localize('Unknown landing company.')}) unless $c_config;

    # BE CAREFUL, do not change ref since it's persistent
    my %landing_company = %{$c_config};

    $landing_company{id} = $country;
    my $registry = LandingCompany::Registry->new;

    foreach my $type ('gaming_company', 'financial_company', 'mt_gaming_company', 'mt_financial_company') {
        if (($landing_company{$type} // '') ne 'none') {
            $landing_company{$type} = __build_landing_company($registry->get($landing_company{$type}));
        } else {
            delete $landing_company{$type};
        }
    }

    return \%landing_company;
}

sub landing_company_details {
    my $params = shift;

    my $lc = LandingCompany::Registry::get($params->{args}->{landing_company_details});
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnknownLandingCompany',
            message_to_client => localize('Unknown landing company.')}) unless $lc;

    return __build_landing_company($lc);
}

sub __build_landing_company {
    my ($lc) = @_;

    return {
        shortcode                         => $lc->short,
        name                              => $lc->name,
        address                           => $lc->address,
        country                           => $lc->country,
        legal_default_currency            => $lc->legal_default_currency,
        legal_allowed_currencies          => $lc->legal_allowed_currencies,
        legal_allowed_markets             => $lc->legal_allowed_markets,
        legal_allowed_contract_categories => $lc->legal_allowed_contract_categories,
        has_reality_check                 => $lc->has_reality_check ? 1 : 0
    };
}

sub statement {
    my $params = shift;

    my $client  = $params->{client};
    my $account = $client->default_account;
    return {
        transactions => [],
        count        => 0
    } unless ($account);

    BOM::RPC::v3::PortfolioManagement::_sell_expired_contracts($client, $params->{source});

    my $results = BOM::Database::DataMapper::Transaction->new({db => $account->db})->get_transactions_ws($params->{args}, $account);

    my @txns;
    foreach my $txn (@$results) {
        my $struct = {
            transaction_id => $txn->{id},
            amount         => $txn->{amount},
            action_type    => $txn->{action_type},
            balance_after  => sprintf('%.2f', $txn->{balance_after}),
            contract_id    => $txn->{financial_market_bet_id},
            payout         => $txn->{payout_price}};

        my $txn_time;
        if (exists $txn->{financial_market_bet_id} and $txn->{financial_market_bet_id}) {
            if ($txn->{action_type} eq 'sell') {
                $struct->{purchase_time} = Date::Utility->new($txn->{purchase_time})->epoch;
                $txn_time = $txn->{sell_time};
            } else {
                $txn_time = $txn->{purchase_time};
            }
        } else {
            $txn_time = $txn->{payment_time};
        }
        $struct->{transaction_time} = Date::Utility->new($txn_time)->epoch;
        $struct->{app_id} = BOM::RPC::v3::Utility::mask_app_id($txn->{source}, $txn_time);

        if ($params->{args}->{description}) {
            $struct->{shortcode} = $txn->{short_code} // '';
            if ($struct->{shortcode} && $account->currency_code) {
                $struct->{longcode} = (simple_contract_info($struct->{shortcode}, $account->currency_code))[0];
            }
            $struct->{longcode} //= $txn->{payment_remark} // '';
        }

        push @txns, $struct;
    }

    return {
        transactions => [@txns],
        count        => scalar @txns
    };
}

sub profit_table {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return {
        transactions => [],
        count        => 0
    } unless ($client);

    BOM::RPC::v3::PortfolioManagement::_sell_expired_contracts($client, $params->{source});

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client_loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client_loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    my $args = $params->{args};
    $args->{after}  = $args->{date_from} if $args->{date_from};
    $args->{before} = $args->{date_to}   if $args->{date_to};
    my $data = $fmb_dm->get_sold_bets_of_account($args);
    # args is passed to echo req hence we need to delete them
    delete $args->{after};
    delete $args->{before};

    ## remove useless and plus new
    my @transactions;
    my $and_description = $args->{description};
    foreach my $row (@{$data}) {
        my %trx = map { $_ => $row->{$_} } (qw/sell_price buy_price/);
        $trx{contract_id}    = $row->{id};
        $trx{transaction_id} = $row->{txn_id};
        $trx{payout}         = $row->{payout_price};
        $trx{purchase_time}  = Date::Utility->new($row->{purchase_time})->epoch;
        $trx{sell_time}      = Date::Utility->new($row->{sell_time})->epoch;
        $trx{app_id}         = BOM::RPC::v3::Utility::mask_app_id($row->{source}, $row->{purchase_time});

        if ($and_description) {
            $trx{shortcode} = $row->{short_code};
            $trx{longcode} = (simple_contract_info($trx{shortcode}, $client->currency))[0];
        }

        push @transactions, \%trx;
    }

    return {
        transactions => \@transactions,
        count        => scalar(@transactions)};
}

sub balance {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return {
        currency => '',
        loginid  => $client_loginid,
        balance  => "0.00"
    } unless ($client->default_account);

    return {
        loginid  => $client_loginid,
        currency => $client->default_account->currency_code,
        balance => sprintf('%.2f', $client->default_account->balance)};
}

sub get_account_status {
    my $params = shift;

    my $client = $params->{client};

    my @status;
    foreach my $s (sort keys %{$client->client_status_types}) {
        next if $s eq 'tnc_approval';    # the useful part for tnc_approval is reason
        push @status, $s if $client->get_status($s);
    }

    push @status, 'authenticated' if ($client->client_fully_authenticated);
    my $risk_classification = $client->aml_risk_classification // '';

    # we need to send only low, standard, high as manual override is for internal purpose
    $risk_classification =~ s/manual override - //;

    return {
        status              => \@status,
        risk_classification => $risk_classification
    };
}

sub change_password {
    my $params = shift;

    my $client = $params->{client};
    my ($token_type, $client_ip, $args) = @{$params}{qw/token_type client_ip args/};

    # allow OAuth token
    unless (($token_type // '') eq 'oauth_token') {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $user = BOM::Platform::User->new({email => $client->email});

    if (
        my $pass_error = BOM::RPC::v3::Utility::_check_password({
                old_password => $args->{old_password},
                new_password => $args->{new_password},
                user_pass    => $user->password
            }))
    {
        return $pass_error;
    }

    my $new_password = BOM::System::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    my $oauth = BOM::Database::Model::OAuth->new;
    foreach my $c1 ($user->clients) {
        $c1->password($new_password);
        $c1->save;

        $oauth->revoke_tokens_by_loginid($c1->loginid);
    }

    BOM::System::AuditLog::log('password has been changed', $client->email);
    send_email({
            from    => Brands->new(name => request()->brand)->emails('support'),
            to      => $client->email,
            subject => localize('Your password has been changed.'),
            message => [
                localize(
                    'The password for your account [_1] has been changed. This request originated from IP address [_2]. If this request was not performed by you, please immediately contact Customer Support.',
                    $client->email,
                    $client_ip
                )
            ],
            use_email_template => 1,
            template_loginid   => $client->loginid,
        });

    return {status => 1};
}

sub cashier_password {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my ($client_ip, $args) = @{$params}{qw/client_ip args/};
    my $unlock_password = $args->{unlock_password} // '';
    my $lock_password   = $args->{lock_password}   // '';

    unless (length($unlock_password) || length($lock_password)) {
        # just return status
        if (length $client->cashier_setting_password) {
            return {status => 1};
        } else {
            return {status => 0};
        }
    }

    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CashierPassword',
            message_to_client => $error,
        });
    };

    if (length($lock_password)) {
        # lock operation
        if (length $client->cashier_setting_password) {
            return $error_sub->(localize('Your cashier was locked.'));
        }

        my $user = BOM::Platform::User->new({email => $client->email});
        if (BOM::System::Password::checkpw($lock_password, $user->password)) {
            return $error_sub->(localize('Please use a different password than your login password.'));
        }

        if (my $pass_error = BOM::RPC::v3::Utility::_check_password({new_password => $lock_password})) {
            return $pass_error;
        }

        $client->cashier_setting_password(BOM::System::Password::hashpw($lock_password));
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Cashier password updated"),
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
                    template_loginid     => $client->loginid,
                });
            return {status => 1};
        }
    } else {
        # unlock operation
        unless (length $client->cashier_setting_password) {
            return $error_sub->(localize('Your cashier was not locked.'));
        }

        my $cashier_password = $client->cashier_setting_password;
        my $salt = substr($cashier_password, 0, 2);
        if (!BOM::System::Password::checkpw($unlock_password, $cashier_password)) {
            BOM::System::AuditLog::log('Failed attempt to unlock cashier', $client->loginid);
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Failed attempt to unlock cashier section"),
                    'message' => [
                        localize(
                            'This is an automated message to alert you to the fact that there was a failed attempt to unlock the Cashier/Settings section of your account [_1] from IP address [_2]',
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
                    template_loginid     => $client->loginid,
                });

            return $error_sub->(localize('Sorry, you have entered an incorrect cashier password'));
        }

        $client->cashier_setting_password('');
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Cashier password updated"),
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
                    template_loginid     => $client->loginid,
                });
            BOM::System::AuditLog::log('cashier unlocked', $client->loginid);
            return {status => 0};
        }
    }
}

sub reset_password {
    my $params = shift;
    my $args   = $params->{args};
    my $email  = BOM::Platform::Token->new({token => $args->{verification_code}})->email;
    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'reset_password')->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    my ($user, @clients);
    $user = BOM::Platform::User->new({email => $email});

    return BOM::RPC::v3::Utility::create_error({
            code              => "InternalServerError",
            message_to_client => localize("Sorry, an error occurred while processing your account.")}) unless $user and @clients = $user->clients;

    # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
    my $client = $clients[0];

    unless ($client->is_virtual) {
        unless ($args->{date_of_birth}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => "DateOfBirthMissing",
                    message_to_client => localize("Date of birth is required.")});
        }
        my $user_dob = $args->{date_of_birth} =~ s/-0/-/gr;    # / (dummy ST3)
        my $db_dob   = $client->date_of_birth =~ s/-0/-/gr;    # /

        return BOM::RPC::v3::Utility::create_error({
                code              => "DateOfBirthMismatch",
                message_to_client => localize("The email address and date of birth do not match.")}) if ($user_dob ne $db_dob);
    }

    if (my $pass_error = BOM::RPC::v3::Utility::_check_password({new_password => $args->{new_password}})) {
        return $pass_error;
    }

    my $new_password = BOM::System::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    foreach my $obj (@clients) {
        $obj->password($new_password);
        $obj->save;
    }

    BOM::System::AuditLog::log('password has been reset', $email, $args->{verification_code});
    send_email({
            from    => Brands->new(name => request()->brand)->emails('support'),
            to      => $email,
            subject => localize('Your password has been reset.'),
            message => [
                localize(
                    'The password for your account [_1] has been reset. If this request was not performed by you, please immediately contact Customer Support.',
                    $email
                )
            ],
            use_email_template => 1,
            template_loginid   => $client->loginid,
        });

    return {status => 1};
}

sub get_settings {
    my $params = shift;

    my $client = $params->{client};

    my ($dob_epoch, $country_code, $country);
    $dob_epoch = Date::Utility->new($client->date_of_birth)->epoch if ($client->date_of_birth);
    if ($client->residence) {
        $country_code = $client->residence;
        $country =
            Brands->new(name => request()->brand)->countries_instance->countries->localized_code2country($client->residence, $params->{language});
    }

    my $client_tnc_status = $client->get_status('tnc_approval');

    # get JP real a/c status, for Japan Virtual a/c client
    my $jp_account_status;
    $jp_account_status = BOM::RPC::v3::Japan::NewAccount::get_jp_account_status($client) if ($client->landing_company->short eq 'japan-virtual');

    # get Japan specific a/c details (eg: daily loss, occupation, trading experience), for Japan real a/c client
    my $jp_real_settings;
    $jp_real_settings = BOM::RPC::v3::Japan::NewAccount::get_jp_settings($client) if ($client->landing_company->short eq 'japan');

    return {
        email         => $client->email,
        country       => $country,
        country_code  => $country_code,
        email_consent => do { my $user = BOM::Platform::User->new({email => $client->email}); ($user && $user->email_consent) ? 1 : 0 },
        (
            $client->is_virtual
            ? ()
            : (
                salutation                     => $client->salutation,
                first_name                     => $client->first_name,
                last_name                      => $client->last_name,
                date_of_birth                  => $dob_epoch,
                address_line_1                 => $client->address_1,
                address_line_2                 => $client->address_2,
                address_city                   => $client->city,
                address_state                  => $client->state,
                address_postcode               => $client->postcode,
                phone                          => $client->phone,
                allow_copiers                  => $client->allow_copiers,
                is_authenticated_payment_agent => ($client->payment_agent and $client->payment_agent->is_authenticated) ? 1 : 0,
                $client_tnc_status ? (client_tnc_status => $client_tnc_status->reason) : (),
            )
        ),
        $jp_account_status ? (jp_account_status => $jp_account_status) : (),
        $jp_real_settings  ? (jp_settings       => $jp_real_settings)  : (),
    };
}

sub set_settings {
    my $params = shift;

    my $client = $params->{client};

    my ($website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/website_name client_ip user_agent language args/};

    my ($residence, $allow_copiers, $err) = ($args->{residence}, $args->{allow_copiers});
    if ($client->is_virtual) {
        # Virtual client can update
        # - residence, if residence not set. But not for Japan
        # - email_consent (common to real account as well)
        if (not $client->residence and $residence and $residence ne 'jp') {
            $client->residence($residence);
            if (not $client->save()) {
                $err = BOM::RPC::v3::Utility::create_error({
                        code              => 'InternalServerError',
                        message_to_client => localize('Sorry, an error occurred while processing your account.')});
            }
        } elsif (
            grep {
                $_ !~ /passthrough|set_settings|email_consent|residence/
            } keys %$args
            )
        {
            # we only allow these keys in virtual set settings any other key will result in permission error
            $err = BOM::RPC::v3::Utility::permission_error();
        }
    } else {
        # real client is not allowed to update residence
        $err = BOM::RPC::v3::Utility::permission_error() if $residence;

        # handle Japan settings update separately
        if ($client->residence eq 'jp') {
            # this may return error or {status => 1}
            $err = BOM::RPC::v3::Japan::NewAccount::set_jp_settings($params);
        }

        $err = BOM::RPC::v3::Utility::permission_error() if $allow_copiers && $client->broker_code ne 'CR';
    }

    if (
        $allow_copiers
        and @{BOM::Database::DataMapper::Copier->new(
                broker_code => $client->broker_code,
                operation   => 'replica'
                )->get_traders({copier_id => $client->loginid})
                || []})
    {
        $err = BOM::RPC::v3::Utility::create_error({
                code              => 'AllowCopiersError',
                message_to_client => localize("Copier can't be a trader.")});
    }

    return $err if $err->{error};

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined $args->{email_consent}) {
        my $user = BOM::Platform::User->new({email => $client->email});
        $user->email_consent($args->{email_consent});
        $user->save;
    }

    if (defined $allow_copiers) {
        $client->allow_copiers($allow_copiers);
    }

    # need to handle for $err->{status} as that come from japan settings
    return {status => 1} if ($client->is_virtual || $err->{status});

    my $now             = Date::Utility->new;
    my $address1        = $args->{'address_line_1'};
    my $address2        = $args->{'address_line_2'} // '';
    my $addressTown     = $args->{'address_city'};
    my $addressState    = $args->{'address_state'};
    my $addressPostcode = $args->{'address_postcode'};
    my $phone           = $args->{'phone'} // '';

    my $cil_message;
    if (   $address1 ne $client->address_1
        or $address2 ne $client->address_2
        or $addressTown ne $client->city
        or $addressState ne $client->state
        or $addressPostcode ne $client->postcode)
    {
        $cil_message =
              'Client ['
            . $client->loginid
            . '] updated his/her address from ['
            . join(' ', $client->address_1, $client->address_2, $client->city, $client->state, $client->postcode)
            . '] to ['
            . join(' ', $address1, $address2, $addressTown, $addressState, $addressPostcode) . ']';
    }

    $client->address_1($address1);
    $client->address_2($address2);
    $client->city($addressTown);
    $client->state($addressState);    # FIXME validate
    $client->postcode($addressPostcode);
    $client->phone($phone);

    $client->latest_environment($now->datetime . ' ' . $client_ip . ' ' . $user_agent . ' LANG=' . $language);
    if (not $client->save()) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InternalServerError',
                message_to_client => localize('Sorry, an error occurred while processing your account.')});
    }

    if ($cil_message) {
        $client->add_note('Update Address Notification', $cil_message);
    }

    my $message = localize(
        'Dear [_1] [_2] [_3],',
        map { encode_entities($_) } BOM::Platform::Locale::translate_salutation($client->salutation),
        $client->first_name, $client->last_name
    ) . "\n\n";

    $message .= localize('Please note that your settings have been updated as follows:') . "\n\n";

    my $residence_country = Locale::Country::code2country($client->residence);

    my @updated_fields = (
        [localize('Email address'),        $client->email],
        [localize('Country of Residence'), $residence_country],
        [localize('Address'),              join(', ', (map { $client->$_ } qw(address_1 address_2 city state postcode)), $residence_country)],
        [localize('Telephone'),            $client->phone]);
    push @updated_fields,
        [
        localize('Receive news and special offers'),
        BOM::Platform::User->new({email => $client->email})->email_consent ? localize("Yes") : localize("No")]
        if exists $args->{email_consent};
    push @updated_fields, [localize('Allow copiers'), $client->allow_copiers ? localize("Yes") : localize("No")]
        if defined $allow_copiers;

    $message .= "<table>";
    foreach my $updated_field (@updated_fields) {
        $message .=
              "<tr><td style='text-align:left'><strong>"
            . encode_entities($updated_field->[0])
            . "</strong></td><td>:</td><td style='text-align:left'>"
            . encode_entities($updated_field->[1])
            . "</td></tr>";
    }
    $message .= "</table>";
    $message .= "\n" . localize('The [_1] team.', $website_name);

    send_email({
        from                  => Brands->new(name => request()->brand)->emails('support'),
        to                    => $client->email,
        subject               => $client->loginid . ' ' . localize('Change in account settings'),
        message               => [$message],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => $client->loginid,
    });
    BOM::System::AuditLog::log('Your settings have been updated successfully', $client->loginid);

    return {status => 1};
}

sub get_self_exclusion {
    my $params = shift;

    my $client = $params->{client};
    return _get_self_exclusion_details($client);
}

sub _get_self_exclusion_details {
    my $client = shift;

    my $get_self_exclusion = {};
    return $get_self_exclusion if $client->is_virtual;

    my $self_exclusion = $client->get_self_exclusion;
    if ($self_exclusion) {
        $get_self_exclusion->{max_balance} = $self_exclusion->max_balance
            if $self_exclusion->max_balance;
        $get_self_exclusion->{max_turnover} = $self_exclusion->max_turnover
            if $self_exclusion->max_turnover;
        $get_self_exclusion->{max_open_bets} = $self_exclusion->max_open_bets
            if $self_exclusion->max_open_bets;
        $get_self_exclusion->{max_losses} = $self_exclusion->max_losses
            if $self_exclusion->max_losses;
        $get_self_exclusion->{max_7day_losses} = $self_exclusion->max_7day_losses
            if $self_exclusion->max_7day_losses;
        $get_self_exclusion->{max_7day_turnover} = $self_exclusion->max_7day_turnover
            if $self_exclusion->max_7day_turnover;
        $get_self_exclusion->{max_30day_losses} = $self_exclusion->max_30day_losses
            if $self_exclusion->max_30day_losses;
        $get_self_exclusion->{max_30day_turnover} = $self_exclusion->max_30day_turnover
            if $self_exclusion->max_30day_turnover;
        $get_self_exclusion->{session_duration_limit} = $self_exclusion->session_duration_limit
            if $self_exclusion->session_duration_limit;

        if (my $until = $self_exclusion->exclude_until) {
            $until = Date::Utility->new($until);
            if (Date::Utility::today->days_between($until) < 0) {
                $get_self_exclusion->{exclude_until} = $until->date;
            }
        }

        if (my $timeout_until = $self_exclusion->timeout_until) {
            $timeout_until = Date::Utility->new($timeout_until);
            if ($timeout_until->is_after(Date::Utility->new)) {
                $get_self_exclusion->{timeout_until} = $timeout_until->epoch;
            }
        }
    }

    return $get_self_exclusion;
}

sub set_self_exclusion {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    # get old from above sub _get_self_exclusion_details
    my $self_exclusion = _get_self_exclusion_details($client);

    ## validate
    my $error_sub = sub {
        my ($error, $field) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => $error,
            message           => '',
            details           => $field
        });
    };

    my %args = %{$params->{args}};
    foreach my $field (
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit/
        )
    {
        my $val      = $args{$field};
        my $is_valid = 0;
        if ($val and $val =~ /^\d+$/ and $val > 0) {
            $is_valid = 1;
            if ($self_exclusion->{$field} and $val > $self_exclusion->{$field}) {
                $is_valid = 0;
            }
        }
        next if $is_valid;

        if ($self_exclusion->{$field}) {
            return $error_sub->(localize('Please enter a number between 0 and [_1].', $self_exclusion->{$field}), $field);
        } else {
            delete $args{$field};
        }
    }

    if (my $session_duration_limit = $args{session_duration_limit}) {
        if ($session_duration_limit > 1440 * 42) {
            return $error_sub->(localize('Session duration limit cannot be more than 6 weeks.'), 'session_duration_limit');
        }
    }

    my $exclude_until = $args{exclude_until};
    if (defined $exclude_until && $exclude_until =~ /^\d{4}\-\d{2}\-\d{2}$/) {
        my $now = Date::Utility->new;
        my $six_month = Date::Utility->new(DateTime->now()->add(months => 6)->ymd);
        my ($exclusion_end, $exclusion_end_error);
        try {
            $exclusion_end = Date::Utility->new($exclude_until);
        }
        catch {
            $exclusion_end_error = 1;
        };
        return $error_sub->(localize('Exclusion time conversion error.'), 'exclude_until') if $exclusion_end_error;

        # checking for the exclude until date which must be larger than today's date
        if (not $exclusion_end->is_after($now)) {
            return $error_sub->(localize('Exclude time must be after today.'), 'exclude_until');
        }

        # checking for the exclude until date could not be less than 6 months
        elsif ($exclusion_end->epoch < $six_month->epoch) {
            return $error_sub->(localize('Exclude time cannot be less than 6 months.'), 'exclude_until');
        }

        # checking for the exclude until date could not be more than 5 years
        elsif ($exclusion_end->days_between($now) > 365 * 5 + 1) {
            return $error_sub->(localize('Exclude time cannot be for more than five years.'), 'exclude_until');
        }
    } else {
        delete $args{exclude_until};
    }

    my $timeout_until = $args{timeout_until};
    if (defined $timeout_until and $timeout_until =~ /^\d+$/) {
        my $now           = Date::Utility->new;
        my $exclusion_end = Date::Utility->new($timeout_until);
        my $six_week      = Date::Utility->new(time() + 6 * 7 * 86400);

        # checking for the timeout until which must be larger than current time
        if ($exclusion_end->is_before($now)) {
            return $error_sub->(localize('Timeout time must be greater than current time.'), 'timeout_until');
        }

        if ($exclusion_end->is_after($six_week)) {
            return $error_sub->(localize('Timeout time cannot be more than 6 weeks.'), 'timeout_until');
        }
    } else {
        delete $args{timeout_until};
    }

    my $message = '';
    if ($args{max_open_bets}) {
        my $ret = $client->set_exclusion->max_open_bets($args{max_open_bets});
        $message .= "- Maximum number of open positions: $ret\n";
    }
    if ($args{max_turnover}) {
        my $ret = $client->set_exclusion->max_turnover($args{max_turnover});
        $message .= "- Daily turnover: $ret\n";
    }
    if ($args{max_losses}) {
        my $ret = $client->set_exclusion->max_losses($args{max_losses});
        $message .= "- Daily losses: $ret\n";
    }
    if ($args{max_7day_turnover}) {
        my $ret = $client->set_exclusion->max_7day_turnover($args{max_7day_turnover});
        $message .= "- 7-Day turnover: $ret\n";
    }
    if ($args{max_7day_losses}) {
        my $ret = $client->set_exclusion->max_7day_losses($args{max_7day_losses});
        $message .= "- 7-Day losses: $ret\n";
    }
    if ($args{max_30day_turnover}) {
        my $ret = $client->set_exclusion->max_30day_turnover($args{max_30day_turnover});
        $message .= "- 30-Day turnover: $ret\n";
    }
    if ($args{max_30day_losses}) {
        my $ret = $client->set_exclusion->max_30day_losses($args{max_30day_losses});
        $message .= "- 30-Day losses: $ret\n";
    }
    if ($args{max_balance}) {
        my $ret = $client->set_exclusion->max_balance($args{max_balance});
        $message .= "- Maximum account balance: $ret\n";
    }
    if ($args{session_duration_limit}) {
        my $ret = $client->set_exclusion->session_duration_limit($args{session_duration_limit});
        $message .= "- Maximum session duration: $ret\n";
    }
    if ($args{exclude_until}) {
        my $ret = $client->set_exclusion->exclude_until($args{exclude_until});
        $message .= "- Exclude from website until: $ret\n";
    }
    if ($args{timeout_until}) {
        my $ret = $client->set_exclusion->timeout_until($args{timeout_until});
        ## convert epoch to datetime string for email
        $ret = Date::Utility->new($ret)->datetime_yyyymmdd_hhmmss_TZ if $ret;
        $message .= "- Timeout from website until: $ret\n";
    }

    if ($message) {
        my $statuses = join '/', map { uc $_->status_code } $client->client_status;
        my $name = ($client->first_name ? $client->first_name . ' ' : '') . $client->last_name;

        my $client_title = sprintf "%s %s%s", $client->loginid, ($name || '?'), ($statuses ? " [$statuses]" : '');

        $message = "Client $client_title set the following self-exclusion limits:\n\n$message";
        my $brand = Brands->new(name => request()->brand);
        send_email({
            from    => $brand->emails('compliance'),
            to      => $brand->emails('compliance') . ',' . $brand->emails('support'),
            subject => "Client set self-exclusion limits",
            message => [$message],
        });
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SetSelfExclusionError',
                message_to_client => localize('Please provide at least one self-exclusion setting.')});
    }

    $client->save();

    return {status => 1};
}

sub api_token {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};

    # check if sub_account loginid is present then check if its valid
    # and assign it to client object
    my $sub_account_loginid = $params->{args}->{sub_account};
    my ($rtn, $sub_account_client);
    if ($sub_account_loginid) {
        $sub_account_client = Client::Account->new({loginid => $sub_account_loginid});
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSubAccount',
                message_to_client => localize('Please provide a valid sub account loginid.')}
        ) if (not $sub_account_client or ($sub_account_client->sub_account_of ne $client->loginid));

        $client = $sub_account_client;
        $rtn->{sub_account} = $sub_account_loginid;
    }

    my $m = BOM::Database::Model::AccessToken->new;
    if ($args->{delete_token}) {
        $m->remove_by_token($args->{delete_token}, $client->loginid);
        $rtn->{delete_token} = 1;
        # send notification to cancel streaming, if we add more streaming
        # for authenticated calls in future, we need to add here as well
        if (defined $params->{account_id}) {
            BOM::System::RedisReplicated::redis_write()->publish(
                'TXNUPDATE::transaction_' . $params->{account_id},
                JSON::to_json({
                        error => {
                            code       => "TokenDeleted",
                            account_id => $params->{account_id}}}));
        }
    }
    if (my $display_name = $args->{new_token}) {
        my $display_name_err;
        if ($display_name =~ /^[\w\s\-]{2,32}$/) {
            if ($m->is_name_taken($client->loginid, $display_name)) {
                $display_name_err = localize('The name is taken.');
            }
        } else {
            $display_name_err = localize('alphanumeric with space and dash, 2-32 characters');
        }
        unless ($display_name_err) {
            my $token_cnt = $m->get_token_count_by_loginid($client->loginid);
            $display_name_err = localize('Max 30 tokens are allowed.') if $token_cnt >= 30;
        }
        if ($display_name_err) {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'APITokenError',
                message_to_client => $display_name_err,
            });
        }
        ## for old API calls (we'll make it required on v4)
        my $scopes = $args->{new_token_scopes} || ['read', 'trade', 'payments', 'admin'];
        $m->create_token($client->loginid, $display_name, @$scopes);
        $rtn->{new_token} = 1;
    }

    $rtn->{tokens} = $m->get_tokens_by_loginid($client->loginid);

    return $rtn;
}

sub tnc_approval {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    if ($params->{args}->{ukgc_funds_protection}) {
        $client->set_status('ukgc_funds_protection', 'system', 'Client acknowledges the protection level of funds');
        if (not $client->save()) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize('Sorry, an error occurred while processing your request.')});
        }
    } else {
        my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
        my $client_tnc_status   = $client->get_status('tnc_approval');

        if (not $client_tnc_status
            or ($client_tnc_status->reason ne $current_tnc_version))
        {
            $client->set_status('tnc_approval', 'system', $current_tnc_version);
            if (not $client->save()) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'InternalServerError',
                        message_to_client => localize('Sorry, an error occurred while processing your request.')});
            }
        }
    }

    return {status => 1};
}

sub login_history {
    my $params = shift;

    my $client = $params->{client};

    my $limit = 10;
    if (exists $params->{args}->{limit}) {
        if ($params->{args}->{limit} > 50) {
            $limit = 50;
        } else {
            $limit = $params->{args}->{limit};
        }
    }

    my $user = BOM::Platform::User->new({email => $client->email});
    my $login_history = $user->find_login_history(
        sort_by => 'history_date desc',
        limit   => $limit
    );

    my @history = ();
    foreach my $record (@{$login_history}) {
        push @history,
            {
            time        => Date::Utility->new($record->history_date)->epoch,
            action      => $record->action,
            status      => $record->successful ? 1 : 0,
            environment => $record->environment
            };
    }

    return {records => [@history]};

}

sub set_account_currency {
    my $params = shift;

    my $client = $params->{client};

    my $currency                 = $params->{currency};
    my $legal_allowed_currencies = $client->landing_company->legal_allowed_currencies;

    my $response = {status => 0};
    if (grep { $_ eq $currency } @{$legal_allowed_currencies}) {
        # no change in default account currency if default account is already set
        if (not $client->default_account and $client->set_default_account($currency)) {
            $response->{status} = 1;
        } else {
            $response->{status} = 0;
        }
    } else {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidCurrency',
                message_to_client => localize("The provided currency [_1] is not applicable for this account.", $currency)});
    }

    return $response;
}

sub set_financial_assessment {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my ($response, $subject, $message);
    try {
        my %financial_data = map { $_ => $params->{args}->{$_} } (keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});
        my $financial_evaluation = BOM::Platform::Account::Real::default::get_financial_assessment_score(\%financial_data);

        my $is_professional = $financial_evaluation->{total_score} < 60 ? 0 : 1;
        $client->financial_assessment({
            data            => encode_json $financial_evaluation->{user_data},
            is_professional => $is_professional
        });
        $client->save;
        $response = {
            score           => $financial_evaluation->{total_score},
            is_professional => $is_professional
        };
        $subject = $client_loginid . ' assessment test details have been updated';
        $message = ["$client_loginid score is " . $financial_evaluation->{total_score}];
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'UpdateAssessmentError',
                message_to_client => localize("Sorry, an error occurred while processing your request.")});
        $subject = "$client_loginid - assessment test details error";
        $message = ["An error occurred while updating assessment test details for $client_loginid. Please handle accordingly."];
    };

    my $brand = Brands->new(name => request()->brand);
    send_email({
        from    => $brand->emails('support'),
        to      => $brand->emails('compliance'),
        subject => $subject,
        message => $message,
    });

    return $response;
}

sub get_financial_assessment {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my $response             = {};
    my $financial_assessment = $client->financial_assessment();
    if ($financial_assessment) {
        my $data = from_json $financial_assessment->data;
        if ($data) {
            foreach my $key (keys %$data) {
                unless ($key =~ /total_score/) {
                    $response->{$key} = $data->{$key}->{answer};
                }
            }
            $response->{score} = $data->{total_score};
        }
    }

    return $response;
}

sub reality_check {
    my $params = shift;

    my $client        = $params->{client};
    my $token_details = $params->{token_details};

    my $has_reality_check = $client->landing_company->has_reality_check;
    return {} unless ($has_reality_check);

    # we get token creation time and as cap limit if creation time is less than 48 hours from current
    # time we default it to 48 hours, default 48 hours was decided To limit our definition of session
    # if you change this please ask compliance first
    my $start = $token_details->{epoch};
    my $tm    = time - 48 * 3600;
    $start = $tm unless $start and $start > $tm;

    # sell expired contracts so that reality check has proper
    # count for open_contract_count
    BOM::Product::Transaction::sell_expired_contracts({
        client => $client,
        source => $params->{source},
    });

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $client->loginid,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    my $data = $txn_dm->get_reality_check_data_of_account(Date::Utility->new($start)) // {};
    if ($data and scalar @$data) {
        $data = $data->[0];
    } else {
        $data = {};
    }

    my $summary = {
        loginid    => $client->loginid,
        start_time => $start
    };

    foreach (("buy_count", "buy_amount", "sell_count", "sell_amount")) {
        $summary->{$_} = $data->{$_} // 0;
    }
    $summary->{currency}            = $data->{currency_code} // '';
    $summary->{potential_profit}    = $data->{pot_profit}    // 0;
    $summary->{open_contract_count} = $data->{open_cnt}      // 0;

    return $summary;
}

sub connect_add {
    my $params = shift;

    my $connection_token = $params->{args}->{connection_token};
    my $oneall           = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => BOM::System::Config::third_party->{oneall}->{public_key},
        private_key => BOM::System::Config::third_party->{oneall}->{private_key},
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;

    if ($data->{response}->{result}->{status}->{code} != 200) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ConnectAdd',
                message_to_client => localize('Failed to get user identity.')});
    }

    my $client = $params->{client};
    my $user = BOM::Platform::User->new({email => $client->email});

    my $provider_data = $data->{response}->{result}->{data};
    my $user_connect  = BOM::Database::Model::UserConnect->new;
    my $res           = $user_connect->insert_connect($user->id, $provider_data);
    if ($res->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ConnectAdd',
                message_to_client => $res->{error}});
    }

    return {status => 1};
}

sub connect_del {
    my $params = shift;

    my $client = $params->{client};
    my $user = BOM::Platform::User->new({email => $client->email});

    my $user_connect = BOM::Database::Model::UserConnect->new;
    my $res = $user_connect->remove_connect($user->id, $params->{args}->{provider});

    return {status => $res ? 1 : 0};
}

sub connect_list {
    my $params = shift;

    my $client = $params->{client};
    my $user = BOM::Platform::User->new({email => $client->email});

    my $user_connect = BOM::Database::Model::UserConnect->new;
    my @providers    = $user_connect->get_connects_by_user_id($user->id);

    return \@providers;
}

1;

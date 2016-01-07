package BOM::RPC::v3::Accounts;

use 5.014;
use strict;
use warnings;

use Date::Utility;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Locale;
use BOM::Platform::Client;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( simple_contract_info );
use BOM::System::Password;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Model::AccessToken;
use BOM::Database::DataMapper::Transaction;

sub payout_currencies {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    my $currencies;
    if ($client) {
        $currencies = [$client->currency];
    } else {
        my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica');
        $currencies = $lc->legal_allowed_currencies;
    }

    return $currencies;
}

sub landing_company {
    my $params = shift;

    my $country  = $params->{args}->{landing_company};
    my $configs  = BOM::Platform::Runtime->instance->countries_list;
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
    my $registry = BOM::Platform::Runtime::LandingCompany::Registry->new;
    if (($landing_company{gaming_company} // '') ne 'none') {
        $landing_company{gaming_company} = __build_landing_company($registry->get($landing_company{gaming_company}));
    } else {
        delete $landing_company{gaming_company};
    }
    if (($landing_company{financial_company} // '') ne 'none') {
        $landing_company{financial_company} = __build_landing_company($registry->get($landing_company{financial_company}));
    } else {
        delete $landing_company{financial_company};
    }

    return \%landing_company;
}

sub landing_company_details {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get($params->{args}->{landing_company_details});
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
    };
}

sub statement {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my ($client, $account);
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    $account = $client->default_account if $client;

    return {
        transactions => [],
        count        => 0
    } unless ($account);

    my $results = BOM::Database::DataMapper::Transaction->new({db => $account->db})->get_transactions_ws($params->{args}, $account);

    my @txns;
    foreach my $txn (@$results) {
        my $struct = {
            transaction_id   => $txn->{id},
            transaction_time => $txn->{t_epoch},
            amount           => $txn->{amount},
            action_type      => $txn->{action_type},
            balance_after    => $txn->{balance_after},
            contract_id      => $txn->{financial_market_bet_id},
        };

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

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    return {
        transactions => [],
        count        => 0
    } unless ($client);

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
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
        $trx{purchase_time}  = Date::Utility->new($row->{purchase_time})->epoch;
        $trx{sell_time}      = Date::Utility->new($row->{sell_time})->epoch;

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

sub send_realtime_balance {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    return BOM::RPC::v3::Utility::permission_error() unless $client;

    return {
        loginid  => $client->loginid,
        currency => $client->default_account->currency_code,
        balance  => $params->{balance_after}};
}

sub balance {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    return BOM::RPC::v3::Utility::permission_error() unless $client;

    return {
        currency => '',
        loginid  => $client->loginid,
        balance  => 0
    } unless ($client->default_account);

    return {
        loginid  => $client->loginid,
        currency => $client->default_account->currency_code,
        balance  => $client->default_account->balance
    };
}

sub get_account_status {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    return [] unless $client;

    my @status;
    foreach my $s (sort keys %{$client->client_status_types}) {
        push @status, $s if $client->get_status($s);
    }

    if (scalar(@status) == 0) {
        push @status, 'active';
    }

    return \@status;
}

sub change_password {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my ($client_loginid, $token_type, $cs_email, $client_ip, $args) =
        ($params->{client_loginid}, $params->{token_type}, $params->{cs_email}, $params->{client_ip}, $params->{args});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    if (not $client or not(($token_type // '') eq 'session_token')) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    ## only allow for Session Token
    return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Permission denied.')}) unless ($token_type // '') eq 'session_token';

    my $user = BOM::Platform::User->new({email => $client->email});

    my $err = sub {
        my ($message) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ChangePasswordError',
            message_to_client => $message
        });
    };

    ## args validation is done with JSON::Schema in entry_point, here we do others
    return $err->(localize('New password is same as old password.'))
        if $args->{new_password} eq $args->{old_password};
    return $err->(localize("Old password is wrong."))
        unless BOM::System::Password::checkpw($args->{old_password}, $user->password);

    my $new_password = BOM::System::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    foreach my $obj ($user->clients) {
        $obj->password($new_password);
        $obj->save;
    }

    BOM::System::AuditLog::log('password has been changed', $client->email);
    send_email({
            from    => $cs_email,
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
        });

    return {status => 1};
}

sub cashier_password {
    my $params = shift;
    my ($client_loginid, $cs_email, $client_ip, $args) = ($params->{client_loginid}, $params->{cs_email}, $params->{client_ip}, $params->{args});

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    if (not $client or $client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }

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

        $client->cashier_setting_password(BOM::System::Password::hashpw($lock_password));
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => $cs_email,
                    'to'      => $client->email,
                    'subject' => $client->loginid . " cashier password updated",
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
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
                    'from'    => $cs_email,
                    'to'      => $client->email,
                    'subject' => $client->loginid . "-Failed attempt to unlock cashier section",
                    'message' => [
                        localize(
                            'This is an automated message to alert you to the fact that there was a failed attempt to unlock the Cashier/Settings section of your account [_1] from IP address [_2]',
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
                });

            return $error_sub->(localize('Sorry, you have entered an incorrect cashier password'));
        }

        $client->cashier_setting_password('');
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => $cs_email,
                    'to'      => $client->email,
                    'subject' => $client->loginid . " cashier password updated",
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template' => 1,
                });
            BOM::System::AuditLog::log('cashier unlocked', $client->loginid);
            return {status => 0};
        }
    }
}

sub get_settings {
    my $params = shift;
    my ($client_loginid, $language) = ($params->{client_loginid}, $params->{language});

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    return BOM::RPC::v3::Utility::permission_error() unless $client;

    return {
        email         => $client->email,
        date_of_birth => Date::Utility->new($client->date_of_birth)->epoch,
        country       => BOM::Platform::Runtime->instance->countries->localized_code2country($client->residence, $language),
        country_code  => $client->residence,
        $client->is_virtual
        ? ()
        : (
            address_line_1   => $client->address_1,
            address_line_2   => $client->address_2,
            address_city     => $client->city,
            address_state    => $client->state,
            address_postcode => $client->postcode,
            phone            => $client->phone,
        ),
    };
}

sub set_settings {
    my $params = shift;
    my ($client_loginid, $website_name, $cs_email, $client_ip, $user_agent, $language, $args) = (
        $params->{client_loginid}, $params->{website_name}, $params->{cs_email}, $params->{client_ip},
        $params->{user_agent},     $params->{language},     $params->{args});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    if (not $client or $client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }

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

    my $message =
        localize('Dear [_1] [_2] [_3],', BOM::Platform::Locale::translate_salutation($client->salutation), $client->first_name, $client->last_name)
        . "\n\n";
    $message .= localize('Please note that your settings have been updated as follows:') . "\n\n";

    my $residence_country = Locale::Country::code2country($client->residence);

    my @updated_fields = (
        [localize('Email address'),        $client->email],
        [localize('Country of Residence'), $residence_country],
        [
            localize('Address'),
            $client->address_1 . ', '
                . $client->address_2 . ', '
                . $client->city . ', '
                . $client->state . ', '
                . $client->postcode . ', '
                . $residence_country
        ],
        [localize('Telephone'), $client->phone],
    );
    $message .= "<table>";
    foreach my $updated_field (@updated_fields) {
        $message .=
              "<tr><td style='text-align:left'><strong>"
            . $updated_field->[0]
            . "</strong></td><td>:</td><td style='text-align:left'>"
            . $updated_field->[1]
            . "</td></tr>";
    }
    $message .= "</table>";
    $message .= "\n" . localize('The [_1] team.', $website_name);

    send_email({
        from               => $cs_email,
        to                 => $client->email,
        subject            => $client->loginid . ' ' . localize('Change in account settings'),
        message            => [$message],
        use_email_template => 1,
    });
    BOM::System::AuditLog::log('Your settings have been updated successfully', $client->loginid);

    return {status => 1};
}

sub get_self_exclusion {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    my $get_self_exclusion = {};
    if (not $client or $client->is_virtual) {
        return $get_self_exclusion;
    }

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
    }

    return $get_self_exclusion,;
}

sub set_self_exclusion {
    my $params = shift;
    my ($client_loginid, $cs_email, $compliance_email, $args) =
        ($params->{client_loginid}, $params->{cs_email}, $params->{compliance_email}, $params->{args});

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    if (not $client or $client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    # get old from above sub get_self_exclusion
    my $self_exclusion = get_self_exclusion({client_loginid => $client_loginid});

    ## validate
    my $error_sub = sub {
        my ($error, $field) = @_;
        my $err = BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => $error,
            message           => '',
            details           => $field
        });
        return $err;
    };

    my %args = %$args;
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
        my $now           = Date::Utility->new;
        my $exclusion_end = Date::Utility->new($exclude_until);
        my $six_month     = Date::Utility->new(DateTime->now()->add(months => 6)->ymd);

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

        ## remove all tokens (FIX for SessionCookie which do not have remove by loginid now)
        ## but it should be OK since we check self_exclusion on every call
        BOM::Database::Model::AccessToken->new->remove_by_loginid($client->loginid);
    }
    if ($message) {
        $message = "Client $client set the following self-exclusion limits:\n\n$message";
        send_email({
            from    => $compliance_email,
            to      => $compliance_email . ',' . $cs_email,
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
    my ($client_loginid, $args) = ($params->{client_loginid}, $params->{args});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    return BOM::RPC::v3::Utility::permission_error() unless $client;

    my $rtn;
    my $m = BOM::Database::Model::AccessToken->new;
    if ($args->{delete_token}) {
        $m->remove_by_token($args->{delete_token});
        $rtn->{delete_token} = 1;
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
        $m->create_token($client->loginid, $display_name);
        $rtn->{new_token} = 1;
    }

    $rtn->{tokens} = $m->get_tokens_by_loginid($client->loginid);

    return $rtn;
}

1;

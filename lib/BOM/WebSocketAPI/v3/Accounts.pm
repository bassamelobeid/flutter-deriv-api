package BOM::WebSocketAPI::v3::Accounts;

use 5.014;
use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;
use Date::Utility;

use BOM::Product::ContractFactory qw( simple_contract_info );
use BOM::Platform::Runtime;
use BOM::Product::Transaction;
use BOM::System::Password;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Locale;

sub landing_company {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $country  = $args->{landing_company};
    my $configs  = BOM::Platform::Runtime->instance->countries_list;
    my $c_config = $configs->{$country};
    unless ($c_config) {
        ($c_config) = grep { $configs->{$_}->{name} eq $country and $country = $_ } keys %$configs;
    }

    return $c->new_error('landing_company', 'UnknownLandingCompany', localize('Unknown landing company.'))
        unless $c_config;

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

    return {
        msg_type        => 'landing_company',
        landing_company => {%landing_company},
    };
}

sub landing_company_details {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get($args->{landing_company_details});
    return $c->new_error('landing_company_details', 'UnknownLandingCompany', localize('Unknown landing company.'))
        unless $lc;

    return {
        msg_type                => 'landing_company_details',
        landing_company_details => __build_landing_company($lc),
    };
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
    my ($c, $args) = @_;

    my $statement = get_transactions($c, $args);
    return {
        echo_req  => $args,
        msg_type  => 'statement',
        statement => $statement,
    };
}

sub get_transactions {
    my ($c, $args) = @_;
    BOM::Platform::Context::request($c->stash('request'));

    my $acc = $c->stash('account');

    return {
        transactions => [],
        count        => 0
    } unless ($acc);

    my $sql = q{
            SELECT
                t.*,
                EXTRACT(EPOCH FROM date_trunc('s', t.transaction_time)) as t_epoch,
                b.short_code,
                p.remark AS payment_remark
            FROM
                (
                    SELECT * FROM transaction.transaction
                    WHERE
                        account_id = ?
                        AND transaction_time < ?
                        AND transaction_time >= ?
                        ##ACTION_TYPE##
                    ORDER BY transaction_time DESC
                    LIMIT ?
                    OFFSET ?
                ) t
                LEFT JOIN bet.financial_market_bet b
                    ON (t.financial_market_bet_id = b.id)
                LEFT JOIN payment.payment p
                    ON (t.payment_id = p.id)
                ORDER BY t.transaction_time DESC
    };

    my $limit  = $args->{limit}  || 100;
    my $offset = $args->{offset} || 0;
    my $dt_fm  = $args->{date_from};
    my $dt_to  = $args->{date_to};

    for ($dt_fm, $dt_to) {
        $_ = eval { Date::Utility->new($_)->datetime } if ($_);
    }
    $dt_fm ||= '1970-01-01';
    $dt_to ||= Date::Utility->today->plus_time_interval('1d')->datetime;

    my $action_type = ($args->{action_type}) ? 'AND action_type = ?' : '';
    $sql =~ s/##ACTION_TYPE##/$action_type/;

    my @binds = ($acc->id, $dt_to, $dt_fm, ($action_type) ? $action_type : (), $limit, $offset);
    my $results = $acc->db->dbh->selectall_arrayref($sql, {Slice => {}}, @binds);

    my @txns;
    foreach my $txn (@$results) {
        my $struct = {
            transaction_id   => $txn->{id},
            transaction_time => $txn->{t_epoch},
            amount           => $txn->{amount},
            action_type      => $txn->{action_type},
            balance_after    => $txn->{balance_after},
            contract_id      => $txn->{financial_market_bet_id},
            shortcode        => $txn->{short_code},
            longcode         => $txn->{payment_remark},
        };

        if ($txn->{short_code}) {
            ($struct->{longcode}, undef, undef) = try { simple_contract_info($txn->{short_code}, $acc->currency_code) };
            $struct->{longcode} = Mojo::DOM->new->parse($struct->{longcode})->all_text;
        }
        push @txns, $struct;
    }

    return {
        transactions => [@txns],
        count        => scalar @txns
    };
}

sub profit_table {
    my ($c, $args) = @_;

    my $profit_table = __get_sold($c, $args);
    return {
        echo_req     => $args,
        msg_type     => 'profit_table',
        profit_table => $profit_table,
    };
}

sub __get_sold {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $client = $c->stash('client');
    my $acc    = $c->stash('account');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    $args->{after}  = $args->{date_from} if $args->{date_from};
    $args->{before} = $args->{date_to}   if $args->{date_to};
    my $data = $fmb_dm->get_sold_bets_of_account($args);
    # args is passed to echo req hence we need to delete them
    delete $args->{after};
    delete $args->{before};

    ## remove useless and plus new
    $data->{transactions} = [];
    my $and_description = $args->{description};
    foreach my $row (@{delete $data->{rows}}) {
        my %trx = map { $_ => $row->{$_} } (qw/sell_price buy_price/);
        $trx{contract_id}    = $row->{id};
        $trx{transaction_id} = $row->{txn_id};
        $trx{purchase_time}  = Date::Utility->new($row->{purchase_time})->epoch;
        $trx{sell_time}      = Date::Utility->new($row->{sell_time})->epoch;

        if ($and_description) {
            $trx{longcode} = '';
            if (my $con = try { BOM::Product::ContractFactory::produce_contract($row->{short_code}, $acc->currency_code) }) {
                $trx{longcode}  = Mojo::DOM->new->parse($con->longcode)->all_text;
                $trx{shortcode} = $con->shortcode;
            }
        }
        push @{$data->{transactions}}, \%trx;
    }

    return $data;
}

sub send_realtime_balance {
    my ($c, $message) = @_;

    my $client = $c->stash('client');
    my $args   = $c->stash('args');

    my $payload = JSON::from_json($message);
    $c->send({
            json => {
                msg_type => 'balance',
                echo_req => $args,
                balance  => {
                    loginid  => $client->loginid,
                    currency => $client->default_account->currency_code,
                    balance  => $payload->{balance_after}}}});
    return;
}

sub balance {
    my ($c, $args) = @_;
    my $log    = $c->app->log;
    my $client = $c->stash('client');

    return {
        msg_type => 'balance',
        balance  => {
            currency => '',
            loginid  => $client->loginid,
            balance  => 0,
        }}
        unless ($client->default_account);

    my $redis   = $c->stash('redis');
    my $channel = ['TXNUPDATE::balance_' . $client->default_account->id];

    if ($args->{subscribe} eq '1') {
        $redis->subscribe($channel, sub { });
    }
    if ($args->{subscribe} eq '0') {
        $redis->unsubscribe($channel, sub { });
    }

    return {
        msg_type => 'balance',
        balance  => {
            loginid  => $client->loginid,
            currency => $client->default_account->currency_code,
            balance  => $client->default_account->balance,
        },
    };
}

sub get_account_status {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my @status;
    foreach my $s (sort keys %{$client->client_status_types}) {
        push @status, $s if $client->get_status($s);
    }

    if (scalar(@status) == 0) {
        push @status, 'active';
    }

    return {
        msg_type           => 'get_account_status',
        get_account_status => \@status
    };
}

sub change_password {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    ## only allow for Session Token
    return $c->new_error('change_password', 'PermissionDenied', localize('Permission denied.'))
        unless ($c->stash('token_type') // '') eq 'session_token';

    my $client_obj = $c->stash('client');
    my $user = BOM::Platform::User->new({email => $client_obj->email});

    my $err = sub {
        my ($message) = @_;
        return $c->new_error('change_password', 'ChangePasswordError', $message);
    };

    ## args validation is done with JSON::Schema in entry_point, here we do others
    return $err->(localize('New password is same as old password.'))
        if $args->{new_password} eq $args->{old_password};
    return $err->(localize("Old password is wrong."))
        unless BOM::System::Password::checkpw($args->{old_password}, $user->password);

    my $new_password = BOM::System::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    foreach my $client ($user->clients) {
        $client->password($new_password);
        $client->save;
    }

    my $r = $c->stash('request');
    BOM::System::AuditLog::log('password has been changed', $client_obj->email);
    send_email({
            from    => $r->website->config->get('customer_support.email'),
            to      => $client_obj->email,
            subject => localize('Your password has been changed.'),
            message => [
                localize(
                    'The password for your account [_1] has been changed. This request originated from IP address [_2]. If this request was not performed by you, please immediately contact Customer Support.',
                    $client_obj->email,
                    $r->client_ip
                )
            ],
            use_email_template => 1,
        });

    return {
        msg_type        => 'change_password',
        change_password => 1
    };
}

sub get_settings {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');

    return {
        msg_type     => 'get_settings',
        get_settings => {
            email   => $client->email,
            country => BOM::Platform::Runtime->instance->countries->localized_code2country($client->residence, $r->language),
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
        }};
}

sub set_settings {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $now    = Date::Utility->new;
    my $client = $c->stash('client');

    BOM::Platform::Context::request($c->stash('request'));

    return $c->new_error('set_settings', 'PermissionDenied', localize('Permission denied.')) if $client->is_virtual;

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

    $client->latest_environment(
        $now->datetime . ' ' . $r->client_ip . ' ' . $c->req->headers->header('User-Agent') . ' LANG=' . $r->language . ' SKIN=');
    if (not $client->save()) {
        return $c->new_error('set_settings', 'InternalServerError', localize('Sorry, an error occurred while processing your account.'));
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
    $message .= "\n" . localize('The [_1] team.', $r->website->display_name);

    send_email({
        from               => $r->website->config->get('customer_support.email'),
        to                 => $client->email,
        subject            => $client->loginid . ' ' . localize('Change in account settings'),
        message            => [$message],
        use_email_template => 1,
    });
    BOM::System::AuditLog::log('Your settings have been updated successfully', $client->loginid);

    return {
        msg_type     => 'set_settings',
        set_settings => 1,
    };
}

sub get_self_exclusion {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');

    my $self_exclusion     = $client->get_self_exclusion;
    my $get_self_exclusion = {};

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

    return {
        msg_type           => 'get_self_exclusion',
        get_self_exclusion => $get_self_exclusion,
    };
}

sub set_self_exclusion {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');

    # get old from above sub get_self_exclusion
    my $self_exclusion = get_self_exclusion($c)->{'get_self_exclusion'};

    ## validate
    my $error_sub = sub {
        my ($c, $error, $field) = @_;
        my $err = $c->new_error('set_self_exclusion', 'SetSelfExclusionError', $error);
        $err->{error}->{field} = $field;
        return $err;
    };

    my %args = %$args;
    foreach my $field (
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit/
        )
    {
        my $val = $args{$field};
        next unless defined $val;
        unless ($val =~ /^\d+/ and $val > 0) {
            delete $args{$field};
            next;
        }
        if ($self_exclusion->{$field} and $val > $self_exclusion->{$field}) {
            return $error_sub->($c, localize('Please enter a number between 0 and [_1].', $self_exclusion->{$field}), $field);
        }
    }

    if (my $session_duration_limit = $args{session_duration_limit}) {
        if ($session_duration_limit > 1440 * 42) {
            return $error_sub->($c, localize('Session duration limit cannot be more than 6 weeks.'), 'session_duration_limit');
        }
    }

    my $exclude_until = $args{exclude_until};
    if (defined $exclude_until && $exclude_until =~ /^\d{4}\-\d{2}\-\d{2}$/) {
        my $now           = Date::Utility->new;
        my $exclusion_end = Date::Utility->new($exclude_until);
        my $six_month     = Date::Utility->new(DateTime->now()->add(months => 6)->ymd);

        # checking for the exclude until date which must be larger than today's date
        if (not $exclusion_end->is_after($now)) {
            return $error_sub->($c, localize('Exclude time must be after today.'), 'exclude_until');
        }

        # checking for the exclude until date could not be less than 6 months
        elsif ($exclusion_end->epoch < $six_month->epoch) {
            return $error_sub->($c, localize('Exclude time cannot be less than 6 months.'), 'exclude_until');
        }

        # checking for the exclude until date could not be more than 5 years
        elsif ($exclusion_end->days_between($now) > 365 * 5 + 1) {
            return $error_sub->($c, localize('Exclude time cannot be for more than five years.'), 'exclude_until');
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
    }
    if ($message) {
        $message = "Client $client set the following self-exclusion limits:\n\n$message";
        my $compliance_email = $c->app_config->compliance->email;
        send_email({
            from    => $compliance_email,
            to      => $compliance_email . ',' . $r->website->config->get('customer_support.email'),
            subject => "Client set self-exclusion limits",
            message => [$message],
        });
    } else {
        return $c->new_error('set_self_exclusion', 'SetSelfExclusionError', localize('Please provide at least one self-exclusion setting.'));
    }

    $client->save();

    return {
        msg_type           => 'set_self_exclusion',
        set_self_exclusion => 1,
    };
}

1;

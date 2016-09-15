package BOM::RPC::v3::Japan::NewAccount;

use strict;
use warnings;

use JSON qw(from_json encode_json);
use DateTime;
use Date::Utility;

use BOM::RPC::v3::Utility;
use BOM::Platform::Locale;
use BOM::Platform::Account::Real::japan;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime;
use BOM::System::AuditLog;
use BOM::Platform::LandingCompany::Registry;

sub get_jp_account_status {
    my $client = shift;

    my $user = BOM::Platform::User->new({email => $client->email});
    my @siblings = $user->clients(disabled_ok => 1);
    my $jp_client = $siblings[0];

    my $jp_account_status;

    if (    @siblings > 1
        and BOM::Platform::LandingCompany::Registry::get_by_broker($client->broker)->short eq 'japan-virtual'
        and BOM::Platform::LandingCompany::Registry::get_by_broker($jp_client->broker)->short eq 'japan')
    {
        if ($jp_client->get_status('disabled')) {
            $jp_account_status->{status} = 'disabled';

            foreach my $status ('jp_knowledge_test_pending', 'jp_knowledge_test_fail', 'jp_activation_pending') {
                if ($jp_client->get_status($status)) {
                    $jp_account_status->{status} = $status;

                    if ($status eq 'jp_knowledge_test_pending') {
                        my $next_dt = _knowledge_test_available_date();
                        $jp_account_status->{next_test_epoch} = $next_dt->epoch;
                    } elsif ($status eq 'jp_knowledge_test_fail') {
                        my $tests      = JSON::from_json($jp_client->financial_assessment->data)->{jp_knowledge_test};
                        my $last_epoch = $tests->[-1]->{epoch};
                        my $next_dt    = _knowledge_test_available_date($last_epoch);

                        $jp_account_status->{last_test_epoch} = $last_epoch;
                        $jp_account_status->{next_test_epoch} = $next_dt->epoch;
                    }
                    last;
                }
            }
        } else {
            $jp_account_status->{status} = 'activated';
        }
    }
    return $jp_account_status;
}

sub _knowledge_test_available_date {
    my $last_test_epoch = shift;

    my $now = DateTime->now;
    $now->set_time_zone('Asia/Tokyo');

    my ($dt, $skip_to_monday);
    if (not $last_test_epoch) {
        # no test is taken so far
        $dt             = $now;
        $skip_to_monday = 1;
    } else {
        # test can only be repeated after 24 hours of business day (exclude weekends)
        #   a) if test taken on Tues 3pm, next test available is on Wed 3pm
        #   b) if test taken on Fri 3pm, next test available is on Mon 3pm
        #   c) if test taken on Tues 3pm, but today is weekends, next test available in on Mon 12am
        # By right no test should already been taken on Sat & Sun, but is handled here just in case.

        $dt = DateTime->from_epoch(epoch => $last_test_epoch);
        $dt->set_time_zone('Asia/Tokyo');
        $dt->add(days => 1);

        # if today is weekends, next test will be avilable on Monday 12am
        if ($now->day_of_week >= 6 and $dt->epoch < $now->epoch) {
            $dt             = $now;
            $skip_to_monday = 1;
        }
    }

    my $dow = $dt->day_of_week;
    if ($dow >= 6) {
        $dt->add(days => (8 - $dow));

        if ($skip_to_monday) {
            # is weekend now, allow test starting from coming Mon 12am JST
            $dt = DateTime->new(
                year      => $dt->year,
                month     => $dt->month,
                day       => $dt->day,
                time_zone => 'Asia/Tokyo',
            );
        }
    }
    return $dt;
}

sub jp_knowledge_test {
    my $params = shift;

    my $client = $params->{client};

    my $user = BOM::Platform::User->new({email => $client->email});
    my @siblings = $user->clients(disabled_ok => 1);
    my $jp_client = $siblings[0];

    # only allowed for VRTJ client, upgrading to JP
    unless (@siblings > 1
        and BOM::Platform::LandingCompany::Registry::get_by_broker($client->broker)->short eq 'japan-virtual'
        and BOM::Platform::LandingCompany::Registry::get_by_broker($jp_client->broker)->short eq 'japan')
    {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $next_dt;

    if ($jp_client->get_status('jp_knowledge_test_pending')) {
        # client haven't taken any test before

        $next_dt = _knowledge_test_available_date();
    } elsif ($jp_client->get_status('jp_knowledge_test_fail')) {
        # can't take test > 1 within same business day

        my $tests      = from_json($jp_client->financial_assessment->data)->{jp_knowledge_test};
        my $last_epoch = $tests->[-1]->{epoch};
        $next_dt = _knowledge_test_available_date($last_epoch);
    } else {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'NotEligible',
            message_to_client => localize('You are not eligible for Japan knowledge test.'),
        });
    }

    my $now = DateTime->now(time_zone => 'Asia/Tokyo');
    if ($now->epoch < $next_dt->epoch) {
        return BOM::RPC::v3::Utility::create_error({
            code => 'TestUnavailableNow',
            message_to_client =>
                localize('Knowledge test is unavailable now, you may take the test on [_1]' . $next_dt->date . ' ' . $next_dt->time),
        });
    }

    my $args = $params->{args};
    my ($score, $status) = @{$args}{'score', 'status'};

    $jp_client->clr_status($_) for ('jp_knowledge_test_pending', 'jp_knowledge_test_fail');
    if ($status eq 'pass') {
        $jp_client->set_status('jp_activation_pending', 'system', 'pending verification documents from client');
    } else {
        $jp_client->set_status('jp_knowledge_test_fail', 'system', "Failed test with score: $score");
    }

    # append result in financial_assessment record
    my $financial_data = from_json($jp_client->financial_assessment->data);

    my $results = $financial_data->{jp_knowledge_test} // [];
    push @{$results},
        {
        score  => $score,
        status => $status,
        epoch  => $now->epoch,
        };
    $financial_data->{jp_knowledge_test} = $results;
    $jp_client->financial_assessment({data => encode_json($financial_data)});

    if (not $jp_client->save()) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InternalServerError',
                message_to_client => localize('Sorry, an error occurred while processing your request.')});
    }

    if ($status eq 'pass') {
        my $email_content = localize(
            'Dear [_1] [_2],

Congratulations on passing the knowledge test for binary options trading.

In the next stage of our account opening process we are required to verify your identity documents and review your eligibility to open a trading account. This will be conducted by our Compliance and Risk Management department upon receipt of your identity documents.

Kindly <u>reply to this email and attach a scanned copy</u> of one of the following approved forms of identity:

[_3]

<ul>
    <li><b>Japan Driving license</b>, front and back sides</li>
    <li><b>Health Insurance card</b>, front and back side</li>
    <li><b>Basic Resident register</b> and separate passport size photograph. If your document contains details of other family members please cover-over with a blank piece of paper when taking the scan</li>
    <li><b>Residence Card</b>, front and back side</li>
</ul>

Please ensure the document contains details of your current address which matches the details that you provided in the basic information section earlier. Please also ensure that the address and other information is easily readable, as otherwise this may delay your application.

We will endeavor to verify your documents within 24 hours, and send you another email when this step has been completed.

Once again, thank you very much for applying to open an account at Binary.com


Yours sincerely,

Customer Support
Binary KK

support@binary.com',
            $jp_client->last_name,
            $jp_client->first_name,
            'https://www.binary.com/ja/get-started-jp#identification-documents'
        );

        send_email({
            from               => BOM::Platform::Runtime->instance->app_config->cs->email,
            to                 => $client->email,
            subject            => localize('Kindly send us your documents for verification.'),
            message            => [$email_content],
            use_email_template => 1,
            template_loginid   => $client->loginid,
        });
        BOM::System::AuditLog::log('Japan Knowledge Test pass for ' . $jp_client->loginid . ' . System email sent to request for docs',
            $client->loginid);
    }

    return {test_taken_epoch => $now->epoch};
}

sub get_jp_settings {
    my $client = shift;

    my $jp_settings;
    if ($client->landing_company->short eq 'japan') {
        $jp_settings->{$_} = $client->$_ for ('gender', 'occupation');

        if ($client->get_self_exclusion and $client->get_self_exclusion->max_losses) {
            $jp_settings->{daily_loss_limit} = $client->get_self_exclusion->max_losses;
        }

        my $assessment = from_json($client->financial_assessment->data);
        $jp_settings->{$_} = $assessment->{$_} for ('trading_purpose', 'hedge_asset', 'hedge_asset_amount');

        $jp_settings->{$_} = $assessment->{$_}->{answer} for qw(
            annual_income
            financial_asset
            trading_experience_equities
            trading_experience_commodities
            trading_experience_foreign_currency_deposit
            trading_experience_margin_fx
            trading_experience_investment_trust
            trading_experience_public_bond
            trading_experience_option_trading
        );
    }
    return $jp_settings;
}

sub set_jp_settings {
    my $params = shift;
    my ($client, $website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/client website_name client_ip user_agent language args/};

    return BOM::RPC::v3::Utility::permission_error() unless ($client->residence eq 'jp' and $args->{jp_settings});
    $args = $args->{jp_settings};

    my $text = {
        'annual_income'                               => localize('{JAPAN ONLY}Annual income'),
        'financial_asset'                             => localize('{JAPAN ONLY}Financial asset'),
        'trading_experience_equities'                 => localize('{JAPAN ONLY}Trading Experience for Equities'),
        'trading_experience_commodities'              => localize('{JAPAN ONLY}Trading Experience for Commodities'),
        'trading_experience_foreign_currency_deposit' => localize('{JAPAN ONLY}Trading Experience for Foreign currency deposit'),
        'trading_experience_margin_fx'                => localize('{JAPAN ONLY}Trading Experience for Margin FX'),
        'trading_experience_investment_trust'         => localize('{JAPAN ONLY}Trading Experience for Investment trust'),
        'trading_experience_public_bond'              => localize('{JAPAN ONLY}Trading Experience for Public and corporation bond'),
        'trading_experience_option_trading'           => localize('{JAPAN ONLY}Trading Experience for OTC derivative (Option) trading'),
        'trading_purpose'                             => localize('{JAPAN ONLY}Purpose of trading'),
        'hedge_asset'                                 => localize('{JAPAN ONLY}Classification of assets requiring hedge'),
        'hedge_asset_amount'                          => localize('{JAPAN ONLY}Amount of hedging assets'),
    };

    my @updated;
    if ($client->occupation && $client->occupation ne $args->{occupation}) {
        push @updated, [localize('{JAPAN ONLY}Occupation'), $client->occupation, $args->{occupation}];
        $client->occupation($args->{occupation});
    }

    my $ori_fin    = JSON::from_json($client->financial_assessment->data);
    my $fin_change = 0;

    # 2016-09-15: Don't remove these localize text, so they ended up in backend .po files for translation
    # After settings change, email is sent to Client & CS. Japan team wants content (value changed) to be in Japanese
    # used in L363

    # Occupation
    localize('{JAPAN ONLY}Office worker');
    localize('{JAPAN ONLY}Director');
    localize('{JAPAN ONLY}Public worker');
    localize('{JAPAN ONLY}Self-employed');
    localize('{JAPAN ONLY}Housewife / Househusband');
    localize('{JAPAN ONLY}Contract / Temporary / Part Time');
    localize('{JAPAN ONLY}Student');
    localize('{JAPAN ONLY}Unemployed');
    localize('{JAPAN ONLY}Others');

    # Income
    localize('{JAPAN ONLY}Less than 1 million JPY');
    localize('{JAPAN ONLY}1-3 million JPY');
    localize('{JAPAN ONLY}3-5 million JPY');
    localize('{JAPAN ONLY}5-10 million JPY');
    localize('{JAPAN ONLY}10-30 million JPY');
    localize('{JAPAN ONLY}30-50 million JPY');
    localize('{JAPAN ONLY}50-100 million JPY');
    localize('{JAPAN ONLY}Over 100 million JPY');

    # Trading Experience
    localize('{JAPAN ONLY}No experience');
    localize('{JAPAN ONLY}Less than 6 months');
    localize('{JAPAN ONLY}6 months to 1 year');
    localize('{JAPAN ONLY}1-3 years');
    localize('{JAPAN ONLY}3-5 years');
    localize('{JAPAN ONLY}Over 5 years');

    # purpose of trading
    localize('{JAPAN ONLY}Targeting short-term profits');
    localize('{JAPAN ONLY}Targeting medium-term / long-term profits');
    localize('{JAPAN ONLY}Both the above');
    localize('{JAPAN ONLY}Hedging');

    # asset hedge
    localize('{JAPAN ONLY}Foreign currency deposit');
    localize('{JAPAN ONLY}Margin FX');
    localize('{JAPAN ONLY}Other');

    foreach my $key (qw(
        trading_purpose
        hedge_asset
        hedge_asset_amount
        annual_income
        financial_asset
        trading_experience_equities
        trading_experience_commodities
        trading_experience_foreign_currency_deposit
        trading_experience_margin_fx
        trading_experience_investment_trust
        trading_experience_public_bond
        trading_experience_option_trading
        ))
    {
        my $ori = $ori_fin->{$key};

        if (not grep { $key eq $_ } qw(trading_purpose hedge_asset hedge_asset_amount)) {
            $ori = $ori->{answer};
        }
        $ori //= '';

        my $new = $args->{$key} // '';

        if ($ori ne $new) {
            push @updated, [$text->{$key}, localize($ori), localize($new)];
            $fin_change = 1;
        }
    }

    # no settings change
    return {status => 1} unless (@updated > 0);

    if ($fin_change == 1) {
        delete $args->{occupation};
        my $new_fin = BOM::Platform::Account::Real::japan::get_financial_assessment_score($args);

        # keep other existing fields, eg: agreement, jp_knowledge_test
        foreach (keys %$ori_fin) {
            if (not exists $new_fin->{$_}) {
                $new_fin->{$_} = $ori_fin->{$_};
            }
        }
        $client->financial_assessment({data => encode_json($new_fin)});
    }

    $client->latest_environment(Date::Utility::new->datetime . ' ' . $client_ip . ' ' . $user_agent . ' LANG=' . $language);
    if (not $client->save()) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InternalServerError',
                message_to_client => localize('Sorry, an error occurred while processing your account.')});
    }

    my $message =
        localize('Dear [_1] [_2] [_3],', BOM::Platform::Locale::translate_salutation($client->salutation), $client->first_name, $client->last_name)
        . "\n\n";

    $message .= localize('Please note that your settings have been updated as follows:') . "\n\n";

    $message .= "<table>";
    foreach my $field (@updated) {
        $message .=
              "<tr><td style='text-align:left'><strong>"
            . $field->[0]
            . "</strong></td><td>:</td><td style='text-align:left'>"
            . $field->[2]
            . "</td></tr>";
    }
    $message .= "</table>";
    $message .= "\n" . localize('The [_1] team.', $website_name);

    send_email({
        from               => BOM::Platform::Runtime->instance->app_config->cs->email,
        to                 => $client->email,
        subject            => $client->loginid . ' ' . localize('Change in account settings'),
        message            => [$message],
        use_email_template => 1,
        template_loginid   => $client->loginid,
    });
    BOM::System::AuditLog::log('Your settings have been updated successfully', $client->loginid);

    my $cs_msg = localize('Please note that client [_1] settings has been updated as below:', $client->loginid) . "\n\n";
    foreach my $field (@updated) {
        $cs_msg .= $field->[0] . ":" . "\n\t" . localize('Old value: ') . $field->[1] . "\n\t" . localize('New value: ') . $field->[2] . "\n\n";
    }
    $client->add_note($client->loginid . ' ' . localize('Japan Client Change in account settings notification'), $cs_msg);

    return {status => 1};
}

1;

package BOM::Platform::Account::Real::japan;

use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use BOM::Platform::Account::Real::default;

sub _validate {
    my $args = shift;
    if (my $error = BOM::Platform::Account::Real::default::validate($args)) {
        return $error;
    }

    my $from_client = $args->{from_client};
    return if ($from_client->residence eq 'jp');

    warn("japan acc opening err: loginid:" . $from_client->loginid . " wrong residence:" . $from_client->residence);
    return {err => 'invalid'};
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $financial_data, $agreement_input) =
        @{$args}{'from_client', 'user', 'country', 'details', 'financial_data', 'agreement'};

    return {error => 'social login user is prohibited'} if $user->has_social_signup;
    my $daily_loss_limit = delete $details->{daily_loss_limit};

    if (my $error = _validate($args)) {
        return $error;
    }

    my $financial_assessment = get_financial_assessment_score($financial_data);
    if ((
               $financial_assessment->{annual_income_score} < 2
            or $financial_assessment->{financial_asset_score} < 2
        )
        or $financial_assessment->{trading_experience_score} < 10
        )
    {
        return {error => 'insufficient score'};
    }
    # store agreement fields in financial_assessment table
    my $agreement = get_agreement($agreement_input);
    return $agreement if ($agreement->{error});

    $financial_assessment->{agreement} = $agreement;

    my $register = BOM::Platform::Account::Real::default::register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data => Encode::encode_utf8(JSON::MaybeXS->new->encode($financial_assessment)),
    });

    $client->set_exclusion->max_losses($daily_loss_limit);
    $client->set_status('jp_knowledge_test_pending', 'system', 'pending knowledge test');
    $client->set_status('disabled',                  'system', 'disabled until Japan account opening process completed');
    $client->set_default_account('JPY');
    $client->save;

    my $response = BOM::Platform::Account::Real::default::after_register_client({
        client      => $client,
        user        => $user,
        details     => $details,
        from_client => $from_client,
        ip          => $args->{ip},
        country     => $args->{country},
    });

    BOM::Platform::Account::Real::default::add_details_to_desk($client, $details);

    return $response;
}

sub agreement_fields {
    return (
        qw/ agree_use_electronic_doc
            agree_warnings_and_policies
            confirm_understand_own_judgment
            confirm_understand_trading_mechanism
            confirm_understand_judgment_time
            confirm_understand_total_loss
            confirm_understand_sellback_loss
            confirm_understand_shortsell_loss
            confirm_understand_company_profit
            confirm_understand_expert_knowledge
            declare_not_fatca /
    );
}

sub get_agreement {
    my $args = shift;

    my $now = Date::Utility->new->datetime;
    my $agreement;
    for (agreement_fields()) {
        unless (($args->{$_} // '') == 1) {
            return {error => 'T&C Error'};
        }

        $agreement->{$_} = $now;
    }
    return $agreement;
}

sub _get_input_to_category_mapping {
    return {
        annual_income                               => 'annual_income_score',
        financial_asset                             => 'financial_asset_score',
        trading_experience_equities                 => 'equities_score',
        trading_experience_commodities              => 'commodities_score',
        trading_experience_foreign_currency_deposit => 'trading_experience_score',
        trading_experience_margin_fx                => 'margin_fx_score',
        trading_experience_investment_trust         => 'trading_experience_score',
        trading_experience_public_bond              => 'trading_experience_score',
        trading_experience_option_trading           => 'binary_options_score',
        motivation_cicumstances                     => 'motivation_cicumstances_score',
    };
}

sub get_financial_input_mapping {
    my $scores = {
        financial_asset_score => {
            'Less than 1 million JPY' => 0,
            '1-3 million JPY'         => 2,
            '3-5 million JPY'         => 3,
            '5-10 million JPY'        => 4,
            '10-30 million JPY'       => 5,
            '30-50 million JPY'       => 6,
            '50-100 million JPY'      => 7,
            'Over 100 million JPY'    => 8,
        },
        annual_income_score => {
            'Less than 1 million JPY' => 0,
            '1-3 million JPY'         => 2,
            '3-5 million JPY'         => 3,
            '5-10 million JPY'        => 4,
            '10-30 million JPY'       => 5,
            '30-50 million JPY'       => 6,
            '50-100 million JPY'      => 7,
            'Over 100 million JPY'    => 8,
        },
        trading_experience_score => {
            'No experience'      => 0,
            'Less than 6 months' => 0,
            '6 months to 1 year' => 0,
            '1-3 years'          => 0,
            '3-5 years'          => 1,
            'Over 5 years'       => 2,
        },
        equities_score => {
            'No experience'      => 0,
            'Less than 6 months' => 0,
            '6 months to 1 year' => 0,
            '1-3 years'          => 1,
            '3-5 years'          => 3,
            'Over 5 years'       => 5,
        },
        commodities_score => {
            'No experience'      => 0,
            'Less than 6 months' => 0,
            '6 months to 1 year' => 1,
            '1-3 years'          => 2,
            '3-5 years'          => 5,
            'Over 5 years'       => 7,
        },
        margin_fx_score => {
            'No experience'      => 0,
            'Less than 6 months' => 2,
            '6 months to 1 year' => 3,
            '1-3 years'          => 7,
            '3-5 years'          => 10,
            'Over 5 years'       => 10,
        },
        binary_options_score => {
            'No experience'      => 0,
            'Less than 6 months' => 5,
            '6 months to 1 year' => 10,
            '1-3 years'          => 10,
            '3-5 years'          => 10,
            'Over 5 years'       => 10,
        },
        motivation_cicumstances_score => {
            'Web Advertisement'            => 0,
            'Homepage'                     => 0,
            'Introduction of acquaintance' => 0,
            'Other'                        => 0,
        },
    };
    my $input_to_category = _get_input_to_category_mapping();

    my $score_map;
    foreach (keys %$input_to_category) {
        $score_map->{$_} = $scores->{$input_to_category->{$_}};
    }
    return $score_map;
}

sub get_financial_assessment_score {
    my $details           = shift;
    my $score_map         = get_financial_input_mapping();
    my $input_to_category = _get_input_to_category_mapping();

    my $data;
    foreach my $key (keys %$score_map) {
        if (my $answer = $details->{$key}) {
            my $score = $score_map->{$key}->{$answer};

            $data->{$key} = {
                answer => $answer,
                score  => $score,
            };
            # categorize scores into: annual_income_score, financial_asset_score, trading_experience_score
            if ($input_to_category->{$key} =~ 'annual_income_score') {
                $data->{$input_to_category->{$key}} += $score;
            } elsif ($input_to_category->{$key} =~ 'financial_asset_score') {
                $data->{$input_to_category->{$key}} += $score;
            } else {
                $data->{'trading_experience_score'} += $score;
            }
            $data->{total_score} += $score;
        }
    }

    foreach ('trading_purpose', 'hedge_asset', 'hedge_asset_amount') {
        $data->{$_} = $details->{$_};
    }

    return $data;
}

1;

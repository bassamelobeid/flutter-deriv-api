package BOM::Platform::Account::Real::japan;

use strict;
use warnings;

use JSON qw(encode_json);
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(send_email);

sub _validate {
    my $args = shift;
    if (my $error = BOM::Platform::Account::Real::default::_validate($args)) {
        return $error;
    }

    my $from_client = $args->{from_client};
    return if ($from_client->residence eq 'jp');

    get_logger()->warn("japan acc opening err: loginid:" . $from_client->loginid . " wrong residence:" . $from_client->residence);
    return {err => 'invalid'};
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $financial_data, $agreement_input) =
        @{$args}{'from_client', 'user', 'country', 'details', 'financial_data', 'agreement'};

    my $daily_loss_limit = delete $details->{daily_loss_limit};

    if (my $error = _validate($args)) {
        return $error;
    }

    my $financial_assessment = get_financial_assessment_score($financial_data);
    if ($financial_assessment->{income_asset_score} < 3 or $financial_assessment->{trading_experience_score} < 10) {
        return {error => 'insufficient score'};
    }
    # store agreement fields in financial_assessment table
    my $agreement = get_agreement($agreement_input);
    return $agreement if ($agreement->{error});

    $financial_assessment->{agreement} = $agreement;

    my $register = BOM::Platform::Account::Real::default::_register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data => encode_json($financial_assessment),
    });

    $client->set_exclusion->max_losses($daily_loss_limit);
    $client->set_status('knowledge_test_pending');
    $client->save;

    return BOM::Platform::Account::Real::default::_after_register_client({
        client  => $client,
        user    => $user,
        details => $details,
    });
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
        annual_income                               => 'income_asset_score',
        financial_asset                             => 'income_asset_score',
        trading_experience_equities                 => 'trading_experience_score',
        trading_experience_commodities              => 'trading_experience_score',
        trading_experience_foreign_currency_deposit => 'trading_experience_score',
        trading_experience_margin_fx                => 'trading_experience_score',
        trading_experience_investment_trust         => 'trading_experience_score',
        trading_experience_public_bond              => 'trading_experience_score',
        trading_experience_option_trading           => 'trading_experience_score',
    };
}

sub get_financial_input_mapping {
    my $scores = {
        income_asset_score => {
            'Less than 1 million JPY' => 1,
            '1-3 million JPY'         => 2,
            '3-5 million JPY'         => 3,
            '5-10 million JPY'        => 4,
            '10-30 million JPY'       => 5,
            '30-50 million JPY'       => 6,
            '50-100 million JPY'      => 7,
            'Over 100 million JPY'    => 8,
        },
        trading_experience_score => {
            'No experience'      => 1,
            'Less than 6 months' => 2,
            '6 months to 1 year' => 3,
            '1-3 years'          => 4,
            '3-5 years'          => 5,
            'Over 5 years'       => 6,
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
            # categorize scores into: income_asset_score, trading_experience_score
            $data->{$input_to_category->{$key}} += $score;
            $data->{total_score} += $score;
        }
    }

    foreach ('trading_purpose', 'hedge_asset', 'hedge_asset_amount') {
        $data->{$_} = $details->{$_};
    }

    return $data;
}

1;

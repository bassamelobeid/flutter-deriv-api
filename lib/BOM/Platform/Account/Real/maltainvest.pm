package BOM::Platform::Account::Real::maltainvest;

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

    # also allow MLT UK client to open MF account
    my $from_client = $args->{from_client};
    my $company = BOM::Platform::Runtime->instance->financial_company_for_country($from_client->residence) // '';
    return if ($company eq 'maltainvest' or ($from_client->residence eq 'gb' and $from_client->landing_company->short eq 'malta'));

    get_logger()
        ->warn(
        "maltainvest acc opening err: loginid:" . $from_client->loginid . " residence:" . $from_client->residence . " financial_company:$company");
    return {error => 'invalid'};
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $financial_assessment) =
        @{$args}{'from_client', 'user', 'country', 'details', 'financial_assessment'};

    if (my $error = _validate($args)) {
        return $error;
    }
    my $register = BOM::Platform::Account::Real::default::_register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data            => encode_json($financial_assessment->{user_data}),
        is_professional => $financial_assessment->{total_score} < 60 ? 0 : 1,
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    $client->save;

    my $status = BOM::Platform::Account::Real::default::_after_register_client({
        client  => $client,
        user    => $user,
        details => $details,
    });

    if ($financial_assessment->{total_score} > 59) {
        send_email({
            from    => request()->website->config->get('customer_support.email'),
            to      => BOM::Platform::Runtime->instance->app_config->compliance->email,
            subject => $client->loginid . ' considered as professional trader',
            message =>
                [$client->loginid . ' scored ' . $financial_assessment->{total_score} . ' and is therefore considered a professional trader.'],
        });
    }
    return $status;
}

sub get_financial_input_mapping {
    my $experience_possible_answer = {
        '0-1 year'     => 0,
        '1-2 years'    => 1,
        'Over 3 years' => 2
    };
    my $frequency_possible_answer = {
        '0-5 transactions in the past 12 months'        => 0,
        '6-10 transactions in the past 12 months'       => 1,
        '40 transactions or more in the past 12 months' => 2
    };

    my $financial_mapping = {
        forex_trading_experience => {
            'label'           => 'Forex trading experience',
            'possible_answer' => $experience_possible_answer
        },
        forex_trading_frequency => {
            'label'           => 'Forex trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        indices_trading_experience => {
            'label'           => 'Indices trading experience',
            'possible_answer' => $experience_possible_answer
        },
        indices_trading_frequency => {
            'label'           => 'Indices trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        commodities_trading_experience => {
            'label'           => 'Commodities trading experience',
            'possible_answer' => $experience_possible_answer
        },
        commodities_trading_frequency => {
            'label'           => 'Commodities trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        stocks_trading_experience => {
            'label'           => 'Stocks trading experience',
            'possible_answer' => $experience_possible_answer
        },
        stocks_trading_frequency => {
            'label'           => 'Stocks trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        other_derivatives_trading_experience => {
            'label'           => 'Binary options or other financial derivatives trading experience',
            'possible_answer' => $experience_possible_answer
        },
        other_derivatives_trading_frequency => {
            'label'           => 'Binary options or other financial derivatives trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        other_instruments_trading_experience => {
            'label'           => 'Other financial instruments trading experience',
            'possible_answer' => $experience_possible_answer
        },
        other_instruments_trading_frequency => {
            'label'           => 'Other financial instruments trading frequency',
            'possible_answer' => $frequency_possible_answer
        },
        employment_industry => {
            'label'           => 'Industry of Employment',
            'possible_answer' => {
                'Construction' => 0,
                'Education'    => 0,
                'Finance'      => 23,
                'Health'       => 0,
                'Tourism'      => 0,
                'Other'        => 0
            }
        },
        education_level => {
            'label'           => 'Level of Education',
            'possible_answer' => {
                'Primary'   => 0,
                'Secondary' => 1,
                'Tertiary'  => 3
            }
        },
        income_source => {
            'label'           => 'Income Source',
            'possible_answer' => {
                'Salaried Employee'       => 0,
                'Self-Employed'           => 0,
                'Investments & Dividends' => 4,
                'Pension'                 => 0,
                'Other'                   => 0
            }
        },
        net_income => {
            'label'           => 'Net Annual Income',
            'possible_answer' => {
                'Less than $25,000'   => 0,
                '$25,000 - $100,000'  => 1,
                '$100,000 - $500,000' => 2,
                'Over $500,000'       => 3
            }
        },
        estimated_worth => {
            'label'           => 'Estimated Net Worth',
            'possible_answer' => {
                'Less than $100,000'    => 0,
                '$100,000 - $250,000'   => 1,
                '$250,000 - $1,000,000' => 2,
                'Over $1,000,000'       => 3
            }}};
    return $financial_mapping;
}

sub get_financial_assessment_score {
    my $details = shift;

    my $evaluated_data    = {};
    my $financial_mapping = get_financial_input_mapping();
    my $json_data         = {};
    my $total_score       = 0;

    foreach my $key (keys %{$financial_mapping}) {
        if (my $answer = $details->{$key}) {
            my $score = $financial_mapping->{$key}->{possible_answer}->{$answer};
            $json_data->{$key}->{label}  = $financial_mapping->{$key}->{label};
            $json_data->{$key}->{answer} = $answer;
            $json_data->{$key}->{score}  = $score;
            $total_score += $score;
        }
    }
    $json_data->{total_score}      = $total_score;
    $evaluated_data->{total_score} = $total_score;
    $evaluated_data->{user_data}   = $json_data;

    return $evaluated_data;
}

1;

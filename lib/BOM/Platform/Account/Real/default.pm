package BOM::Platform::Account::Real::default;

use strict;
use warnings;
use feature 'state';
use Date::Utility;
use Try::Tiny;
use Locale::Country;
use List::MoreUtils qw(any);
use DataDog::DogStatsd::Helper qw(stats_inc);
use Data::Validate::Sanctions;

use Brands;
use Client::Account;
use Client::Account::Desk;

use BOM::Database::ClientDB;
use BOM::System::Config;
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request);
use BOM::Platform::Account;

sub validate {
    my $args = shift;
    my ($from_client, $user) = @{$args}{'from_client', 'user'};
    my $country = $args->{country} || '';

    my $details;
    my ($broker, $residence) = ('', '');
    if ($details = $args->{details}) {
        ($broker, $residence) = @{$details}{'broker_code', 'residence'};
    }

    my $msg = "acc opening err: from_loginid[" . $from_client->loginid . "], broker[$broker], country[$country], residence[$residence], error: ";

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        warn($msg . 'new account opening suspended');
        return {error => 'invalid'};
    }
    if ($country and Brands->new(name => request()->brand)->countries_instance->restricted_country($country)) {
        warn($msg . "restricted IP country [$country]");
        return {error => 'invalid'};
    }
    unless ($user->email_verified) {
        return {error => 'email unverified'};
    }
    unless ($from_client->residence) {
        return {error => 'no residence'};
    }

    if ($details) {
        # sub account can have different residence then omnibus master account
        if (Brands->new(name => request()->brand)->countries_instance->restricted_country($residence)
            or (not $details->{sub_account_of} and $from_client->residence ne $residence))
        {
            warn($msg . "restricted residence [$residence], or mismatch with from_client residence: " . $from_client->residence);
            return {error => 'invalid residence'};
        }
        if ($residence eq 'gb' and not $details->{address_postcode}) {
            return {error => 'invalid UK postcode'};
        }
        if (   ($details->{address_line_1} || '') =~ /p[\.\s]+o[\.\s]+box/i
            or ($details->{address_line_2} || '') =~ /p[\.\s]+o[\.\s]+box/i)
        {
            return {error => 'invalid PO Box'};
        }
        # check for duplicate email when sub_account_of is not present (omnibus)
        if ((any { $_->loginid =~ qr/^($broker)\d+$/ } ($user->loginid)) and not $details->{sub_account_of}) {
            return {error => 'duplicate email'};
        }
        if (BOM::Database::ClientDB->new({broker_code => $broker})->get_duplicate_client($details)) {
            return {error => 'duplicate name DOB'};
        }

        # mininum age check: Estonia = 21, others = 18
        my $dob_date     = Date::Utility->new($details->{date_of_birth});
        my $minimumAge   = ($residence eq 'ee') ? 21 : 18;
        my $now          = Date::Utility->new;
        my $mmyy         = $now->months_ahead(-12 * $minimumAge);
        my $day_of_month = $now->day_of_month;
        # we should pay special attention to 02-29 because maybe there is no such date $minimumAge years ago
        if ($day_of_month == 29 && $now->month == 2) {
            $day_of_month = $day_of_month - 1;
        }
        my $cutoff = Date::Utility->new($day_of_month . '-' . $mmyy);
        if ($dob_date->is_after($cutoff)) {
            return {error => 'too young'};
        }
    }
    return;
}

sub create_account {
    my $args = shift;
    my ($user, $details) = @{$args}{'user', 'details'};

    if (my $error = validate($args)) {
        return $error;
    }
    my $register = register_client($details);
    return $register if ($register->{error});

    my $response = after_register_client({
        client  => $register->{client},
        user    => $user,
        details => $details,
    });

    add_details_to_desk($register->{client}, $details);

    return $response;
}

sub register_client {
    my $details = shift;

    my ($client, $error);
    try { $client = Client::Account->register_and_return_new_client($details); }
    catch {
        $error = $_;
    };
    if ($error) {
        warn("Real: register_and_return_new_client err [$error]");
        return {error => 'invalid'};
    }
    return {client => $client};
}

sub after_register_client {
    my $args = shift;
    my ($client, $user, $details) = @{$args}{'client', 'user', 'details'};

    if (not $client->is_virtual) {
        $client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
        $client->save;
    }
    $user->add_loginid({loginid => $client->loginid});
    $user->save;

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);
    state $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::System::Config::sanction_file);
    if ($sanctions->is_sanctioned($client->first_name, $client->last_name)) {
        $client->set_status('disabled', 'system', 'client disabled as marked as UNTERR');
        $client->save;
        $client->add_note('UNTERR', "UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list.");
        my $brand = Brands->new(name => request()->brand);
        send_email({
            from    => $brand->emails('support'),
            to      => $brand->emails('compliance'),
            subject => $client->loginid . ' marked as UNTERR',
            message => ["UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list."],
        });
    }

    my $notemsg = "$client_loginid - Name and Address\n\n\n\t\t $client_name \n\t\t";
    my @address = map { $client->$_ } qw(address_1 address_2 city state postcode);
    $notemsg .= join("\n\t\t", @address, Locale::Country::code2country($client->residence));
    $client->add_note("New Sign-Up Client [$client_loginid] - Name And Address Details", "$notemsg\n");

    if ($client->landing_company->short eq 'iom'
        and (length $client->first_name < 3 or length $client->last_name < 3))
    {
        $notemsg = "$client_loginid - first name or last name less than 3 characters \n\n\n\t\t";
        $notemsg .= join("\n\t\t",
            'first name: ' . $client->first_name,
            'last name: ' . $client->last_name,
            'residence: ' . Locale::Country::code2country($client->residence));
        $client->add_note("MX Client [$client_loginid] - first name or last name less than 3 characters", "$notemsg\n");
    }

    stats_inc("business.new_account.real");
    stats_inc("business.new_account.real." . $client->broker);

    return {
        client => $client,
        user   => $user,
    };
}

sub add_details_to_desk {
    my ($client, $details) = @_;

    if (BOM::System::Config::on_production()) {
        try {
            my $desk_api = Client::Account::Desk->new({
                desk_url     => BOM::System::Config::third_party->{desk}->{api_uri},
                api_key      => BOM::System::Config::third_party->{desk}->{api_key},
                secret_key   => BOM::System::Config::third_party->{desk}->{api_key_secret},
                token        => BOM::System::Config::third_party->{desk}->{access_token},
                token_secret => BOM::System::Config::third_party->{desk}->{access_token_secret},
            });

            $details->{loginid}  = $client->loginid;
            $details->{language} = request()->language;
            $desk_api->upload($details);
        }
        catch {
            warn("Unable to add loginid " . $client->loginid . "(" . $client->email . ") to desk.com API: $_");
        };
    }

    return;
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
                'Finance'      => 15,
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
                '$25,000 - $50,000'   => 1,
                '$50,001 - $100,000'  => 2,
                '$100,001 - $500,000' => 3,
                'Over $500,000'       => 4
            }
        },
        estimated_worth => {
            'label'           => 'Estimated Net Worth',
            'possible_answer' => {
                'Less than $100,000'    => 0,
                '$100,000 - $250,000'   => 1,
                '$250,001 - $500,000'   => 2,
                '$500,001 - $1,000,000' => 3,
                'Over $1,000,000'       => 4
            }
        },
        account_opening_reason => {
            'label'           => 'Purpose and reason for requesting the account opening',
            'possible_answer' => {
                "Speculative"    => 0,
                "Income Earning" => 0,
                "Assets Saving"  => 0,
                "Hedging"        => 0,
            }
        },
        occupation => {
            'label'           => 'Occupation',
            'possible_answer' => {
                'Chief Executives, Senior Officials and Legislators'        => 0,
                'Managers'                                                  => 0,
                'Professionals'                                             => 0,
                'Clerks'                                                    => 0,
                'Personal Care, Sales and Service Workers'                  => 0,
                'Agricultural, Forestry and Fishery Workers'                => 0,
                'Craft, Metal, Electrical and Electronics Workers'          => 0,
                'Plant and Machine Operators and Assemblers'                => 0,
                'Cleaners and Helpers'                                      => 0,
                'Mining, Construction, Manufacturing and Transport Workers' => 0,
                'Armed Forces'                                              => 0,
                'Government Officers'                                       => 0,
                'Others'                                                    => 0
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

sub validate_account_details {
    my ($args, $client, $broker, $source) = @_;

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        latest_environment            => '',
        source                        => $source,
    };

    my $affiliate_token;
    $affiliate_token = delete $args->{affiliate_token} if (exists $args->{affiliate_token});
    $details->{myaffiliates_token} = $affiliate_token || $client->myaffiliates_token || '';

    if ($args->{date_of_birth} and $args->{date_of_birth} =~ /^(\d{4})-(\d\d?)-(\d\d?)$/) {
        my $dob_error;
        try {
            $args->{date_of_birth} = Date::Utility->new($args->{date_of_birth})->date;
        }
        catch {
            $dob_error = {error => 'InvalidDateOfBirth'};
        };
        return $dob_error if $dob_error;
    }

    foreach my $key (get_account_fields()) {
        my $value = $args->{$key};
        $value = BOM::Platform::Client::Utility::encrypt_secret_answer($value) if ($key eq 'secret_answer' and $value);

        if (not $client->is_virtual) {
            $value ||= $client->$key;
        }
        $details->{$key} = $value || '';

        # Japan real a/c has NO salutation
        next if (any { $key eq $_ } qw(address_line_2 address_state address_postcode salutation));
        return {error => 'InsufficientAccountDetails'} if (not $details->{$key});
    }
    return {details => $details};
}

sub get_account_fields {
    return qw(salutation first_name last_name date_of_birth residence address_line_1 address_line_2
        address_city address_state address_postcode phone secret_question secret_answer);
}

1;

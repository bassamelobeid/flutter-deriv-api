package BOM::Backoffice::Form;

use strict;
use warnings;

use Date::Utility;
use HTML::FormBuilder;
use HTML::FormBuilder::Validation;
use HTML::FormBuilder::Select;
use JSON::MaybeXS;
use Locale::SubCountry;

use BOM::Backoffice::Request qw(request localize template);
use BOM::Platform::Locale;
use BOM::User::Client;

sub get_self_exclusion_form {
    my $arg_ref = shift;
    my $client  = $arg_ref->{client};

    my $loginID = $client->loginid;

    my (
        $limit_max_ac_bal,    $limit_daily_turn_over,  $limit_open_position, $limit_daily_losses,   $limit_7day_turnover,
        $limit_7day_losses,   $limit_session_duration, $limit_exclude_until, $limit_30day_turnover, $limit_30day_losses,
        $limit_timeout_until, $limit_max_deposit,      $limit_max_deposit_end_date
    );
    my $self_exclusion = $client->get_self_exclusion;
    my $se_map         = '{}';
    if ($self_exclusion) {
        $limit_max_ac_bal           = $self_exclusion->max_balance;
        $limit_daily_turn_over      = $self_exclusion->max_turnover;
        $limit_open_position        = $self_exclusion->max_open_bets;
        $limit_daily_losses         = $self_exclusion->max_losses;
        $limit_7day_losses          = $self_exclusion->max_7day_losses;
        $limit_7day_turnover        = $self_exclusion->max_7day_turnover;
        $limit_30day_losses         = $self_exclusion->max_30day_losses;
        $limit_30day_turnover       = $self_exclusion->max_30day_turnover;
        $limit_session_duration     = $self_exclusion->session_duration_limit;
        $limit_exclude_until        = $self_exclusion->exclude_until;
        $limit_timeout_until        = $self_exclusion->timeout_until;
        $limit_max_deposit          = $self_exclusion->max_deposit;
        $limit_max_deposit_end_date = $self_exclusion->max_deposit_end_date;

        $limit_max_deposit_end_date = Date::Utility->new($limit_max_deposit_end_date)->date if $limit_max_deposit_end_date;

        if ($limit_exclude_until) {
            $limit_exclude_until = Date::Utility->new($limit_exclude_until);
            # Don't uplift exclude_until date for clients under Binary (Europe) Ltd,
            # Binary (IOM) Ltd, or Binary Investments (Europe) Ltd upon expiry.
            # This is in compliance with Section 3.5.4 (5e) of the United Kingdom Gambling
            # Commission licence conditions and codes of practice
            # United Kingdom Gambling Commission licence conditions and codes of practice is
            # applicable to clients under Binary (Europe) Ltd & Binary (IOM) Ltd only. Change is also
            # applicable to clients under Binary Investments (Europe) Ltd for standardisation.
            # (http://www.gamblingcommission.gov.uk/PDF/LCCP/Licence-conditions-and-codes-of-practice.pdf)
            if (Date::Utility::today()->days_between($limit_exclude_until) >= 0 && $client->landing_company->short !~ /^(?:iom|malta|maltainvest)$/) {
                undef $limit_exclude_until;
            } else {
                $limit_exclude_until = $limit_exclude_until->date;
            }
        }

        if ($limit_timeout_until) {
            $limit_timeout_until = Date::Utility->new($limit_timeout_until);
            if ($limit_timeout_until->is_before(Date::Utility->new)) {
                undef $limit_timeout_until;
            } else {
                $limit_timeout_until = $limit_timeout_until->datetime_yyyymmdd_hhmmss;
            }

        }

        $se_map = {
            'MAXCASHBAL'         => $limit_max_ac_bal           // '',
            'DAILYTURNOVERLIMIT' => $limit_daily_turn_over      // '',
            'MAXOPENPOS'         => $limit_open_position        // '',
            'DAILYLOSSLIMIT'     => $limit_daily_losses         // '',
            '7DAYLOSSLIMIT'      => $limit_7day_losses          // '',
            '7DAYTURNOVERLIMIT'  => $limit_7day_turnover        // '',
            '30DAYLOSSLIMIT'     => $limit_30day_losses         // '',
            '30DAYTURNOVERLIMIT' => $limit_30day_turnover       // '',
            'SESSIONDURATION'    => $limit_session_duration     // '',
            'EXCLUDEUNTIL'       => $limit_exclude_until        // '',
            'TIMEOUTUNTIL'       => $limit_timeout_until        // '',
            'MAXDEPOSIT'         => $limit_max_deposit          // '',
            'MAXDEPOSITDATE'     => $limit_max_deposit_end_date // '',
        };
        $se_map = JSON::MaybeXS->new->encode($se_map);

        my %htmlesc = (qw/< &lt; > &gt; " &quot; & &amp;/);
        $se_map =~ s/([<>"&])/$htmlesc{$1}/ge;
    }

    my $curr_regex = LandingCompany::Registry::get_currency_type($client->currency) eq 'fiat' ? '^\d*\.?\d{0,2}$' : '^\d*\.?\d{0,8}$';

    #input field for Maximum account cash balance
    my $input_field_maximum_account_cash_balance = {
        'label' => {
            'text' => localize('Maximum account cash balance'),
            'for'  => 'MAXCASHBAL',
        },
        'input' => {
            'id'    => 'MAXCASHBAL',
            'name'  => 'MAXCASHBAL',
            'type'  => 'text',
            'value' => $limit_max_ac_bal,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'errorMAXCASHBAL',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Once this limit is reached, you may no longer deposit.')}};

    #input field for Daily Turnover limit
    my $input_field_daily_turnover_limit = {
        'label' => {
            'text' => localize('Daily turnover limit'),
            'for'  => 'DAILYTURNOVERLIMIT',
        },
        'input' => {
            'id'    => 'DAILYTURNOVERLIMIT',
            'name'  => 'DAILYTURNOVERLIMIT',
            'type'  => 'text',
            'value' => $limit_daily_turn_over,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'errorDAILYTURNOVERLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate contract purchases per day.')}};

    # Daily Losses limit
    my $input_field_daily_loss_limit = {
        'label' => {
            'text' => localize('Daily limit on losses'),
            'for'  => 'DAILYLOSSLIMIT',
        },
        'input' => {
            'id'    => 'DAILYLOSSLIMIT',
            'name'  => 'DAILYLOSSLIMIT',
            'type'  => 'text',
            'value' => $limit_daily_losses,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'errorDAILYLOSSLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate loss per day.')}};

    #input field for 7-day Turnover limit
    my $input_field_7day_turnover_limit = {
        'label' => {
            'text' => localize('7-day turnover limit'),
            'for'  => '7DAYTURNOVERLIMIT',
        },
        'input' => {
            'id'    => '7DAYTURNOVERLIMIT',
            'name'  => '7DAYTURNOVERLIMIT',
            'type'  => 'text',
            'value' => $limit_7day_turnover,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'error7DAYTURNOVERLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate contract purchases over a 7-day period.')}};

    #input field for 7-day loss limit
    my $input_field_7day_loss_limit = {
        'label' => {
            'text' => localize('7-day limit on losses'),
            'for'  => '7DAYLOSSLIMIT',
        },
        'input' => {
            'id'    => '7DAYLOSSLIMIT',
            'name'  => '7DAYLOSSLIMIT',
            'type'  => 'text',
            'value' => $limit_7day_losses,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'error7DAYLOSSLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate loss over a 7-day period.')}};

    #input field for 30-day Turnover limit
    my $input_field_30day_turnover_limit = {
        'label' => {
            'text' => localize('30-day turnover limit'),
            'for'  => '30DAYTURNOVERLIMIT',
        },
        'input' => {
            'id'    => '30DAYTURNOVERLIMIT',
            'name'  => '30DAYTURNOVERLIMIT',
            'type'  => 'text',
            'value' => $limit_30day_turnover,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'error30DAYTURNOVERLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate contract purchases over a 30-day period.')}};

    #input field for 30-day loss limit
    my $input_field_30day_loss_limit = {
        'label' => {
            'text' => localize('30-day limit on losses'),
            'for'  => '30DAYLOSSLIMIT',
        },
        'input' => {
            'id'    => '30DAYLOSSLIMIT',
            'name'  => '30DAYLOSSLIMIT',
            'type'  => 'text',
            'value' => $limit_30day_losses,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'error30DAYLOSSLIMIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Maximum aggregate loss over a 30-day period.')}};

    my $input_field_max_deposit_limit = {
        'label' => {
            'text' => localize('Maximum deposit'),
            'for'  => 'MAXDEPOSIT',
        },
        'input' => {
            'id'    => 'MAXDEPOSIT',
            'name'  => 'MAXDEPOSIT',
            'type'  => 'text',
            'value' => $limit_max_deposit,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => localize('Please enter a numeric value.'),
            },
        ],
        'error' => {
            'id'    => 'errorMAXDEPOSIT',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Once maximum deposit limit is reached the client may no longer deposit.')}};
    my $input_field_max_deposit_end_date = {
        'label' => {
            'text' => localize('Maximum deposit limit expiry date'),
            'for'  => 'MAXDEPOSITDATE',
        },
        'input' => {
            'id'    => 'MAXDEPOSITDATE',
            'name'  => 'MAXDEPOSITDATE',
            'type'  => 'text',
            'value' => $limit_max_deposit_end_date,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(|\d{4}-\d\d-\d\d)$',
                'err_msg' => localize('Please enter date in the format YYYY-MM-DD.'),
            },
        ],
        'error' => {
            'id'    => 'errorMAXDEPOSITDATE',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Please enter date in the format YYYY-MM-DD.')}};

    #input field for Maximum number of open positions
    my $input_field_maximum_number_open_positions = {
        'label' => {
            'text' => localize('Maximum number of open positions'),
            'for'  => 'MAXOPENPOS',
        },
        'input' => {
            'id'    => 'MAXOPENPOS',
            'name'  => 'MAXOPENPOS',
            'type'  => 'text',
            'value' => $limit_open_position,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(\d*)$',
                'err_msg' => localize('Please enter an integer value.'),
            },
        ],
        'error' => {
            'id'    => 'errorMAXOPENPOS',
            'class' => 'errorfield',
        }};

    #input field for Session duration limit,
    my $input_field_session_duration = {
        'label' => {
            'text' => localize('Session duration limit, in minutes'),
            'for'  => 'SESSIONDURATION',
        },
        'input' => {
            'id'    => 'SESSIONDURATION',
            'name'  => 'SESSIONDURATION',
            'type'  => 'text',
            'value' => $limit_session_duration,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(\d*)$',
                'err_msg' => localize('Please enter an integer value.'),
            },
            {
                'type' => 'custom',
                # Note, this relies on parseInt('') being NaN and NaN>=0 being false and NaN<=max being false
                'function' =>
                    qq{(function(max){var v=input_element_SESSIONDURATION.value; if(v==='') return true; parseInt(v);return v>=0 && v<=max})(1440 * 42)},
                'err_msg' => localize('Session duration limit cannot be more than 6 weeks.'),
            },
        ],
        'error' => {
            'id'    => 'errorSESSIONDURATION',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('You will be automatically logged out after such time.')}};

    #input field for Exclude me from the website until
    my $input_field_exclude_me = {
        'label' => {
            'text' => localize('Exclude me from the website until'),
            'for'  => 'EXCLUDEUNTIL',
        },
        'input' => {
            'id'    => 'EXCLUDEUNTIL',
            'name'  => 'EXCLUDEUNTIL',
            'type'  => 'text',
            'value' => $limit_exclude_until,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(|\d{4}-\d\d-\d\d)$',
                'err_msg' => localize('Please enter date in the format YYYY-MM-DD.'),
            },
        ],
        'error' => {
            'id'    => 'errorEXCLUDEUNTIL',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Please enter date in the format YYYY-MM-DD.')}};

    my $input_field_timeout_me = {
        'label' => {
            'text' => localize('Timeout from the website until'),
            'for'  => 'TIMEOUTUNTIL',
        },
        'input' => {
            'id'    => 'TIMEOUTUNTIL',
            'name'  => 'TIMEOUTUNTIL',
            'type'  => 'text',
            'value' => $limit_timeout_until,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(|((\d{4}-\d{2}-\d{2})+(\s\d{2}:\d{2}:\d{2})?))$',
                'err_msg' => localize('Please enter date in the format YYYY-MM-DD or YYYY-MM-DD hh::mm::ss'),
            },
        ],
        'error' => {
            'id'    => 'errorTIMEOUTUNTIL',
            'class' => 'errorfield',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => localize('Please enter date in the format YYYY-MM-DD or YYYY-MM-DD hh::mm::ss. It will save in GMT format.')}};

    my $input_hidden_fields = {
        'input' => [{
                'type'  => 'hidden',
                'id'    => 'l',
                'name'  => 'l',
                'value' => request()->language,
            },
            {
                'type'  => 'hidden',
                'id'    => 'loginid',
                'name'  => 'loginid',
                'value' => $loginID,
            },
            {
                'type'  => 'hidden',
                'id'    => 'action',
                'name'  => 'action',
                'value' => 'process',
            },
        ],
    };

    my $input_submit_button = {
        'label' => {},
        'input' => {
            'id'    => 'self_exclusion_submit',
            'name'  => 'submit',
            'type'  => 'submit',
            'value' => localize('Update Settings')
        },
        'error' => {
            'id'    => 'invalidinputfound',
            'class' => 'errorfield'
        },

    };

    #instantiate the form object
    my $form_self_exclusion = HTML::FormBuilder::Validation->new(
        data => {
            'id'     => 'selfExclusion',
            'name'   => 'selfExclusion',
            'class'  => 'formObject',
            'method' => 'post',
            'action' => request()->url_for('backoffice/f_setting_selfexclusion.cgi'),
        });

    # add a fieldset to append input fields
    my $fieldset = $form_self_exclusion->add_fieldset({});

    $fieldset->add_field($input_field_maximum_account_cash_balance);
    $fieldset->add_field($input_field_daily_turnover_limit);
    $fieldset->add_field($input_field_daily_loss_limit);
    $fieldset->add_field($input_field_7day_turnover_limit);
    $fieldset->add_field($input_field_7day_loss_limit);
    $fieldset->add_field($input_field_30day_turnover_limit);
    $fieldset->add_field($input_field_30day_loss_limit);
    $fieldset->add_field($input_field_maximum_number_open_positions);
    $fieldset->add_field($input_field_session_duration);
    $fieldset->add_field($input_field_exclude_me);
    $fieldset->add_field($input_field_timeout_me);
    $fieldset->add_field($input_field_max_deposit_limit);
    $fieldset->add_field($input_field_max_deposit_end_date);

    $fieldset->add_field($input_hidden_fields);
    $fieldset->add_field($input_submit_button);

    my $server_side_validation_sub = sub {
        my $session_duration = $form_self_exclusion->get_field_value('SESSIONDURATION') // '';
        my $exclude_until    = $form_self_exclusion->get_field_value('EXCLUDEUNTIL')    // '';
        my $timeout_until    = $form_self_exclusion->get_field_value('TIMEOUTUNTIL')    // '';

        # This check is done both for BO and UI
        if (not $form_self_exclusion->is_error_found_in('SESSIONDURATION') and $session_duration and $session_duration > 1440 * 42) {
            $form_self_exclusion->set_field_error_message('SESSIONDURATION', localize('Session duration limit cannot be more than 6 weeks.'));
        }

        if ($exclude_until
            and not $form_self_exclusion->is_error_found_in('EXCLUDEUNTIL'))
        {
            my $now           = Date::Utility->new;
            my $exclusion_end = Date::Utility->new($exclude_until);
            my $six_month     = Date::Utility->new->plus_time_interval('6mo')->truncate_to_day;

            #server side checking for the exclude until date which must be larger than today's date
            if (not $exclusion_end->is_after($now)) {
                $form_self_exclusion->set_field_error_message('EXCLUDEUNTIL', localize('Exclude time must be after today.'));
            }

            #server side checking for the exclude until date could not be less than 6 months
            elsif ($exclusion_end->epoch < $six_month->epoch) {
                $form_self_exclusion->set_field_error_message('EXCLUDEUNTIL', localize('Exclude time cannot be less than 6 months.'));
            }

            #server side checking for the exclude until date could not be more than 5 years
            elsif ($exclusion_end->days_between($now) > 365 * 5 + 1) {
                $form_self_exclusion->set_field_error_message('EXCLUDEUNTIL', localize('Exclude time cannot be for more than five years.'));
            }
        }

        if ($timeout_until
            and not $form_self_exclusion->is_error_found_in('TIMEOUTUNTIL'))
        {
            my $now           = Date::Utility->new;
            my $exclusion_end = Date::Utility->new($timeout_until);
            my $six_week      = Date::Utility->new(time() + 6 * 7 * 86400);

            #server side checking for the exclude until date which must be larger than today's date
            if (not $exclusion_end->is_after($now)) {
                $form_self_exclusion->set_field_error_message('TIMEOUTUNTIL', localize('Timeout time must be greater than current time.'));
            }

            if ($exclusion_end->is_after($six_week)) {
                $form_self_exclusion->set_field_error_message('TIMEOUTUNTIL', localize('Timeout time cannot be more than 6 weeks.'));
            }
        }
    };

    $form_self_exclusion->set_server_side_checks($server_side_validation_sub);
    return $form_self_exclusion;
}

sub get_payment_agent_registration_form {
    my ($loginid, $brokercode) = @_;

    # input field for pa_name
    my $input_field_pa_name = {
        'label' => {
            'text' => localize('Your name/company'),
            'for'  => 'pa_name',
        },
        'input' => {
            'id'        => 'pa_name',
            'name'      => 'pa_name',
            'type'      => 'text',
            'maxlength' => 60,
        },
        'error' => {
            'id'    => 'errorpa_name',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^.{1,60}$',
                'err_msg' => localize('Please enter a valid name.'),
            },
        ]};

    # input field for pa_summary
    my $input_field_pa_summary = {
        'label' => {
            'text' => localize('Short summary of your Payment Agent service'),
            'for'  => 'pa_summary'
        },
        'input' => {
            'id'        => 'pa_summary',
            'name'      => 'pa_summary',
            'type'      => 'text',
            'maxlength' => 60,
        },
        'error' => {
            'id'    => 'errorpa_summary',
            'class' => 'errorfield'
        },
    };

    # Input field for pa_email
    my $input_field_pa_email = {
        'label' => {
            'text' => localize('Your email address'),
            'for'  => 'pa_email',
        },
        'input' => {
            'id'        => 'pa_email',
            'name'      => 'pa_email',
            'type'      => 'text',
            'maxlength' => 100,
        },
        'error' => {
            'id'    => 'errorpa_email',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '\w+',
                'err_msg' => localize('Please enter your email address.'),
            },
            {
                'type'    => 'regexp',
                'regexp'  => _email_check_regexp(),
                'err_msg' => localize('Sorry, you have entered an incorrect email address.'),
            },
        ]};

    # input field for pa_tel
    my $input_field_pa_tel = {
        'label' => {
            'text' => localize('Your phone number'),
            'for'  => 'pa_tel',
        },
        'input' => {
            'id'        => 'pa_tel',
            'name'      => 'pa_tel',
            'type'      => 'text',
            'maxlength' => 35,
        },
        'error' => {
            'id'    => 'errorpa_tel',
            'class' => 'errorfield',
        },
        'validation' => [
            # min length = 6
            {
                'type'    => 'regexp',
                'regexp'  => '^(|.{6}.*)$',
                'err_msg' => localize('Invalid telephone number (too short).'),
            },
            # max length = 35
            {
                'type'    => 'regexp',
                'regexp'  => '^.{0,35}$',
                'err_msg' => localize('Invalid telephone number (too long).'),
            },
            {
                'type'    => 'regexp',
                'regexp'  => '^(|\+?[0-9\s]+)$',
                'err_msg' => localize('Invalid telephone number.'),
            },
        ],
    };

    # input field for pa_url
    my $input_field_pa_url = {
        'label' => {
            'text' => localize('Your website URL'),
            'for'  => 'pa_url'
        },
        'input' => {
            'id'        => 'pa_url',
            'name'      => 'pa_url',
            'type'      => 'text',
            'maxlength' => 100,
        },
        'error' => {
            'id'    => 'errorpa_url',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(https?:\/\/[^\s]+)?$',
                'err_msg' => localize('This URL is invalid.'),
            },
        ],
    };

    # Commision value options
    my $commision_option = [map { {value => $_} } qw(0 0.1 0.25 0.5 0.75 1 2 2.5 3 3.5 4 4.5 5 6 7 8 9)];

    # input field for pa_comm_depo
    my $input_field_pa_comm_depo = {
        'label' => {
            'text' => localize('Commission (%) you want to take on deposits'),
            'for'  => 'pa_comm_depo',
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_comm_depo',
            'name'    => 'pa_comm_depo',
            'options' => $commision_option,
        ),
        'error' => {
            'id'    => 'errorpa_comm_depo',
            'class' => 'errorfield'
        },
    };

    # input field for pa_comm_with
    my $input_field_pa_comm_with = {
        'label' => {
            'text' => localize('Commission (%) you want to take on withdrawals'),
            'for'  => 'pa_comm_with',
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_comm_with',
            'name'    => 'pa_comm_with',
            'options' => $commision_option,
        ),
        'error' => {
            'id'    => 'errorpa_comm_with',
            'class' => 'errorfield'
        },
    };

    my $input_field_pa_max_withdrawal = {
        'label' => {
            'text' => localize('Max withdrawal limit'),
            'for'  => 'pa_max_withdrawal'
        },
        'input' => {
            'id'        => 'pa_max_withdrawal',
            'name'      => 'pa_max_withdrawal',
            'type'      => 'text',
            'maxlength' => 10,
        },
        'error' => {
            'id'    => 'errorpa_max_withdrawal',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(?![+-])(?:[1-9]\d*|0)?(?:.\d+)?$',
                'err_msg' => localize('Please enter a positive numeric value.'),
            },
        ],
    };

    my $input_field_pa_min_withdrawal = {
        'label' => {
            'text' => localize('Min withdrawal limit'),
            'for'  => 'pa_min_withdrawal'
        },
        'input' => {
            'id'        => 'pa_min_withdrawal',
            'name'      => 'pa_min_withdrawal',
            'type'      => 'text',
            'maxlength' => 10,
        },
        'error' => {
            'id'    => 'errorpa_min_withdrawal',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(?![+-])(?:[1-9]\d*|0)?(?:.\d+)?$',
                'err_msg' => localize('Please enter a positive numeric value.'),
            },
        ],
    };

    # Input field for pa_info
    my $textarea_pa_info = {
        'label' => {
            'text' => localize('Please provide some information about yourself and your proposed services'),
            'for'  => 'pa_info',
        },
        'input' => {
            'id'      => 'pa_info',
            'name'    => 'pa_info',
            'type'    => 'textarea',
            'row'     => 10,
            'cols'    => 60,
            'maxsize' => '500',
        },
        'error' => {
            'text'  => '',
            'id'    => 'errorpa_info',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(.|\n){0,500}$',
                'err_msg' => localize('Comment must not exceed [_1] characters. Please resubmit.', 500),
            },

        ],
    };

    # Input field for pa_supported_banks
    my $input_field_pa_supported_banks = {
        'label' => {
            'text' => localize('Supported banks'),
            'for'  => 'pa_supported_banks'
        },
        'input' => {
            'id'        => 'pa_supported_banks',
            'name'      => 'pa_supported_banks',
            'type'      => 'text',
            'maxlength' => 500,
        },
        'error' => {
            'id'    => 'errorpa_suported_banks',
            'class' => 'errorfield'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^[0-9a-zA-Z,]*$',
                'err_msg' => localize('Supported banks list is invalid'),
            },
        ],
        comment => {
            'text' => '** Comma-separated list (no spaces) of: ' . (join ' ', _get_payment_agent_banks()),
        }};

    # Input field for pa_auth
    my $input_field_pa_auth = {
        'label' => {
            'text' => localize('AUTHORISED PAYMENT AGENT?'),
            'for'  => 'pa_auth'
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_auth',
            'name'    => 'pa_auth',
            'values'  => ['0'],
            'options' => _select_yes_no(),
        )};

    # Input field for pa_listed
    my $input_field_pa_listed = {
        'label' => {
            'text' => localize('LISTED PAYMENT AGENT?'),
            'for'  => 'pa_listed'
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_listed',
            'name'    => 'pa_listed',
            'values'  => ['0'],
            'options' => _select_yes_no(),
        )};

    my $input_hidden_field_whattodo = {
        'id'    => 'whattodo',
        'name'  => 'whattodo',
        'type'  => 'hidden',
        'value' => 'apply'
    };

    my $hidden_fields = {'input' => [_input_hidden_field_language(), $input_hidden_field_whattodo]};

    my $input_submit_button = {
        'label' => {},
        'input' => {
            'id'    => 'submit',
            'name'  => 'submit',
            'type'  => 'submit',
            'value' => localize('Submit')}};

    my $form_action = request()->url_for("/paymentagent/application");

    if ($loginid) {
        my $input_hidden_field_loginid = {
            'id'    => 'loginid',
            'name'  => 'loginid',
            'type'  => 'hidden',
            'value' => $loginid
        };
        push @{$hidden_fields->{'input'}}, $input_hidden_field_loginid;

        my $input_hidden_field_broker = {
            'id'    => 'broker',
            'name'  => 'broker',
            'type'  => 'hidden',
            'value' => $brokercode
        };
        push @{$hidden_fields->{'input'}}, $input_hidden_field_broker;

        $form_action = request()->url_for("backoffice/f_setting_paymentagent.cgi");
    }

    #declare the form attributes
    my $form_attributes = {
        'name'   => 'paymentAgentRegistrationForm',
        'id'     => 'paymentAgentRegistrationForm',
        'class'  => 'formObject',
        'method' => 'post',
        'action' => $form_action,
    };

    #instantiate the form object
    my $form_object = HTML::FormBuilder::Validation->new(data => $form_attributes);

    my $fieldset = $form_object->add_fieldset({});

    $fieldset->add_field($input_field_pa_name);
    $fieldset->add_field($input_field_pa_summary);
    $fieldset->add_field($input_field_pa_email);
    $fieldset->add_field($input_field_pa_tel);
    $fieldset->add_field($input_field_pa_url);
    $fieldset->add_field($input_field_pa_comm_depo);
    $fieldset->add_field($input_field_pa_comm_with);
    $fieldset->add_field($input_field_pa_max_withdrawal);
    $fieldset->add_field($input_field_pa_min_withdrawal);
    $fieldset->add_field($textarea_pa_info);

    if ($input_field_pa_supported_banks) {
        $fieldset->add_field($input_field_pa_supported_banks);
    }
    if ($input_field_pa_auth) {
        $fieldset->add_field($input_field_pa_auth);
    }
    if ($input_field_pa_listed) {
        $fieldset->add_field($input_field_pa_listed);
    }
    $fieldset->add_field($hidden_fields);
    $fieldset->add_field($input_submit_button);

    return $form_object;
}

sub _input_hidden_field_language {
    return {
        'id'    => 'l',
        'name'  => 'l',
        'type'  => 'hidden',
        'value' => request()->language
    };
}

sub _select_yes_no {
    return [{
            value => '',
            text  => localize('Please select')
        },
        {
            value => 'yes',
            text  => localize('Yes')
        },
        {
            value => 'no',
            text  => localize('No')}];
}

sub _email_check_regexp {
    return '^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$';
}

# better to maintain the sort order else use sort before returning
sub _get_payment_agent_banks {
    return
        qw(AlertPay Alipay BNI BankBRI CIMBNIAGA DiamondBank EGold FirstBank GTBank GrupBCA ICBC LibertyReserve Mandiri MandiriSyariah MasterCard MoneyGram PayPal PerfectMoney PermataBank SolidTrustPay VISA Verve WeChatPay ZenithBank);
}

1;

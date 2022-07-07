package BOM::Backoffice::Form;

use strict;
use warnings;

use Date::Utility;
use HTML::FormBuilder;
use HTML::FormBuilder::Validation;
use HTML::FormBuilder::Select;
use JSON::MaybeXS;
use Locale::SubCountry;
use Digest::SHA qw(sha256_hex);

use BOM::Backoffice::Request qw(request);
use BOM::Platform::Locale;
use BOM::User::Client;
use BOM::User::Client::PaymentAgent;

use constant SALT_FOR_CSRF_TOKEN => 'emDWVx1SH68JE5N1ba9IGz5fb';

sub get_self_exclusion_form {
    my $arg_ref         = shift;
    my $client          = $arg_ref->{client};
    my $restricted_only = $arg_ref->{restricted_only};

    my $regulated             = $client->landing_company->is_eu;
    my $deposit_limit_enabled = $client->landing_company->deposit_limit_enabled;
    my $loginID               = $client->loginid;

    my (
        $limit_max_ac_bal,    $limit_daily_turn_over,  $limit_open_position, $limit_daily_losses,   $limit_7day_turnover,
        $limit_7day_losses,   $limit_session_duration, $limit_exclude_until, $limit_30day_turnover, $limit_30day_losses,
        $limit_timeout_until, $limit_daily_deposit,    $limit_7day_deposit,  $limit_30day_deposit
    );

    my $self_exclusion = $client->get_self_exclusion;
    my $se_map         = '{}';
    if ($self_exclusion) {
        $limit_max_ac_bal       = $self_exclusion->max_balance;
        $limit_daily_turn_over  = $self_exclusion->max_turnover;
        $limit_open_position    = $self_exclusion->max_open_bets;
        $limit_daily_losses     = $self_exclusion->max_losses;
        $limit_7day_losses      = $self_exclusion->max_7day_losses;
        $limit_7day_turnover    = $self_exclusion->max_7day_turnover;
        $limit_30day_losses     = $self_exclusion->max_30day_losses;
        $limit_30day_turnover   = $self_exclusion->max_30day_turnover;
        $limit_session_duration = $self_exclusion->session_duration_limit;
        $limit_exclude_until    = $self_exclusion->exclude_until;
        $limit_timeout_until    = $self_exclusion->timeout_until;
        $limit_daily_deposit    = $self_exclusion->max_deposit_daily;
        $limit_7day_deposit     = $self_exclusion->max_deposit_7day;
        $limit_30day_deposit    = $self_exclusion->max_deposit_30day;

        if ($limit_exclude_until) {
            $limit_exclude_until = Date::Utility->new($limit_exclude_until);
            # Don't uplift exclude_until date for clients under Deriv (Europe) Limited,
            # Deriv (MX) Ltd, or Deriv Investments (Europe) Limited upon expiry.
            # This is in compliance with Section 3.5.4 (5e) of the United Kingdom Gambling
            # Commission licence conditions and codes of practice
            # United Kingdom Gambling Commission licence conditions and codes of practice is
            # applicable to clients under Deriv (Europe) Limited & Deriv (MX) Ltd only. Change is also
            # applicable to clients under Deriv Investments (Europe) Limited for standardisation.
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
            'MAXCASHBAL'         => $limit_max_ac_bal       // '',
            'DAILYTURNOVERLIMIT' => $limit_daily_turn_over  // '',
            'MAXOPENPOS'         => $limit_open_position    // '',
            'DAILYLOSSLIMIT'     => $limit_daily_losses     // '',
            '7DAYLOSSLIMIT'      => $limit_7day_losses      // '',
            '7DAYTURNOVERLIMIT'  => $limit_7day_turnover    // '',
            '30DAYLOSSLIMIT'     => $limit_30day_losses     // '',
            '30DAYTURNOVERLIMIT' => $limit_30day_turnover   // '',
            'SESSIONDURATION'    => $limit_session_duration // '',
            'EXCLUDEUNTIL'       => $limit_exclude_until    // '',
            'TIMEOUTUNTIL'       => $limit_timeout_until    // '',
            'DAILYDEPOSITLIMIT'  => $limit_daily_deposit    // '',
            '7DAYDEPOSITLIMIT'   => $limit_7day_deposit     // '',
            '30DAYDEPOSITLIMIT'  => $limit_30day_deposit    // '',
        };
        $se_map = JSON::MaybeXS->new->encode($se_map);

        my %htmlesc = (qw/< &lt; > &gt; " &quot; & &amp;/);
        $se_map =~ s/([<>"&])/$htmlesc{$1}/ge;
    }

    my $curr_regex = LandingCompany::Registry::get_currency_type($client->currency) eq 'fiat' ? '^\d*\.?\d{0,2}$' : '^\d*\.?\d{0,8}$';

    #input field for Maximum account cash balance
    my $input_field_maximum_account_cash_balance = {
        'label' => {
            'text' => 'Maximum account cash balance',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'errorMAXCASHBAL',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Once this limit is reached, you may no longer deposit.',
        }};

    #input field for Daily Turnover limit
    my $input_field_daily_turnover_limit = {
        'label' => {
            'text' => 'Daily turnover limit',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'errorDAILYTURNOVERLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate contract purchases per day.',
        }};

    # Daily Losses limit
    my $input_field_daily_loss_limit = {
        'label' => {
            'text' => 'Daily limit on losses',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'errorDAILYLOSSLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate loss per day.',
        }};

    #input field for 7-day Turnover limit
    my $input_field_7day_turnover_limit = {
        'label' => {
            'text' => '7-day turnover limit',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error7DAYTURNOVERLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate contract purchases over a 7-day period.',
        }};

    #input field for 7-day loss limit
    my $input_field_7day_loss_limit = {
        'label' => {
            'text' => '7-day limit on losses',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error7DAYLOSSLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate loss over a 7-day period.',
        }};

    #input field for 30-day Turnover limit
    my $input_field_30day_turnover_limit = {
        'label' => {
            'text' => '30-day turnover limit',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error30DAYTURNOVERLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate contract purchases over a 30-day period.',
        }};

    #input field for 30-day loss limit
    my $input_field_30day_loss_limit = {
        'label' => {
            'text' => '30-day limit on losses',
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
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error30DAYLOSSLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate loss over a 30-day period.',
        }};

    my $input_field_daily_deposit_limit = {
        'label' => {
            'text' => 'Daily limit on deposits',
            'for'  => 'DAILYDEPOSITLIMIT',
        },
        'input' => {
            'id'    => 'DAILYDEPOSITLIMIT',
            'name'  => 'DAILYDEPOSITLIMIT',
            'type'  => 'text',
            'value' => $limit_daily_deposit,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'errorDAILYDEPOSITLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate deposit per day.',
        }};
    my $input_field_7day_deposit_limit = {
        'label' => {
            'text' => '7-day limit on deposits',
            'for'  => '7DAYDEPOSITLIMIT',
        },
        'input' => {
            'id'    => '7DAYDEPOSITLIMIT',
            'name'  => '7DAYDEPOSITLIMIT',
            'type'  => 'text',
            'value' => $limit_7day_deposit,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error7DAYDEPOSITLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate deposit over a 7-day period',
        }};
    my $input_field_30day_deposit_limit = {
        'label' => {
            'text' => '30-day limit on deposits',
            'for'  => '30DAYDEPOSITLIMIT',
        },
        'input' => {
            'id'    => '30DAYDEPOSITLIMIT',
            'name'  => '30DAYDEPOSITLIMIT',
            'type'  => 'text',
            'value' => $limit_30day_deposit,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => $curr_regex,
                'err_msg' => 'Please enter a numeric value.',
            },
        ],
        'error' => {
            'id'    => 'error30DAYDEPOSITLIMIT',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Maximum aggregate deposit over a 30-day period',
        }};

    #input field for Maximum number of open positions
    my $input_field_maximum_number_open_positions = {
        'label' => {
            'text' => 'Maximum number of open positions',
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
                'err_msg' => 'Please enter an integer value.',
            },
        ],
        'error' => {
            'id'    => 'errorMAXOPENPOS',
            'class' => 'error',
        }};

    #input field for Session duration limit,
    my $input_field_session_duration = {
        'label' => {
            'text' => 'Session duration limit, in minutes',
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
                'err_msg' => 'Please enter an integer value.',
            },
            {
                'type' => 'custom',
                # Note, this relies on parseInt('') being NaN and NaN>=0 being false and NaN<=max being false
                'function' =>
                    qq{(function(max){var v=input_element_SESSIONDURATION.value; if(v==='') return true; parseInt(v);return v>=0 && v<=max})(1440 * 42)},
                'err_msg' => 'Session duration limit cannot be more than 6 weeks.',
            },
        ],
        'error' => {
            'id'    => 'errorSESSIONDURATION',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'You will be automatically logged out after such time.',
        }};

    #input field for Exclude me from the website until
    my $input_field_exclude_me = {
        'label' => {
            'text' => 'Exclude me from the website until',
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
                'err_msg' => 'Please enter date in the format YYYY-MM-DD.',
            },
        ],
        'error' => {
            'id'    => 'errorEXCLUDEUNTIL',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Please enter date in the format YYYY-MM-DD.',
        }};

    my $input_field_timeout_me = {
        'label' => {
            'text' => 'Timeout from the website until',
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
                'err_msg' => 'Please enter date in the format YYYY-MM-DD or YYYY-MM-DD hh::mm::ss',
            },
        ],
        'error' => {
            'id'    => 'errorTIMEOUTUNTIL',
            'class' => 'error',
        },
        'comment' => {
            'class' => 'hint',
            'text'  => 'Please enter date in the format YYYY-MM-DD or YYYY-MM-DD hh::mm::ss. It will save in GMT format.',
        }};

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
            'value' => 'Update Settings',
            'class' => 'btn btn--primary'
        },
        'error' => {
            'id'    => 'invalidinputfound',
            'class' => 'error'
        },

    };

    my $params = {loginid => $loginID};

    #instantiate the form object
    my $form_self_exclusion = HTML::FormBuilder::Validation->new(
        data => {
            'id'     => 'selfExclusion',
            'name'   => 'selfExclusion',
            'class'  => 'formObject',
            'method' => 'post',
            'action' => request()->url_for(
                $restricted_only
                ? 'backoffice/f_setting_selfexclusion_restricted.cgi'
                : 'backoffice/f_setting_selfexclusion.cgi', $params
            )});

    my @restricted_fields = (
        $input_field_daily_loss_limit, $deposit_limit_enabled ? ($input_field_daily_deposit_limit) : (),
        $input_field_7day_loss_limit,  $deposit_limit_enabled ? ($input_field_7day_deposit_limit)  : (),
        $input_field_30day_loss_limit, $deposit_limit_enabled ? ($input_field_30day_deposit_limit) : (),
    );

    # add a fieldset to append input fields
    my $fieldset = $form_self_exclusion->add_fieldset({});
    if ($restricted_only) {
        $fieldset->add_field($_) for @restricted_fields;
    } else {
        if ($regulated) {
            $_->{input}->{readonly} = 1 for @restricted_fields;
        }

        $fieldset->add_field($input_field_maximum_account_cash_balance);
        $fieldset->add_field($input_field_daily_turnover_limit);
        $fieldset->add_field($input_field_daily_loss_limit);
        $fieldset->add_field($input_field_daily_deposit_limit) if $deposit_limit_enabled;
        $fieldset->add_field($input_field_7day_turnover_limit);
        $fieldset->add_field($input_field_7day_loss_limit);
        $fieldset->add_field($input_field_7day_deposit_limit) if $deposit_limit_enabled;
        $fieldset->add_field($input_field_30day_turnover_limit);
        $fieldset->add_field($input_field_30day_loss_limit);
        $fieldset->add_field($input_field_30day_deposit_limit) if $deposit_limit_enabled;
        $fieldset->add_field($input_field_maximum_number_open_positions);
        $fieldset->add_field($input_field_session_duration);
        $fieldset->add_field($input_field_exclude_me);
        $fieldset->add_field($input_field_timeout_me);
    }
    $fieldset->add_field($input_hidden_fields);
    $fieldset->add_field($input_submit_button);

    my $server_side_validation_sub = sub {
        my $session_duration   = $form_self_exclusion->get_field_value('SESSIONDURATION') // '';
        my $max_deposit_expiry = $form_self_exclusion->get_field_value('MAXDEPOSITDATE')  // '';
        my $max_deposit        = $form_self_exclusion->get_field_value('MAXDEPOSIT')      // '';

        my $now = Date::Utility->new;

        # This check is done both for BO and UI
        if (not $form_self_exclusion->is_error_found_in('SESSIONDURATION') and $session_duration and $session_duration > 1440 * 42) {
            $form_self_exclusion->set_field_error_message('SESSIONDURATION', 'Session duration limit cannot be more than 6 weeks.');
        }

        _validate_date_field(
            $form_self_exclusion,
            'EXCLUDEUNTIL',
            'min' => {
                date    => $now->plus_time_interval('6mo')->truncate_to_day,
                message => 'Exclude time cannot be less than 6 months.'
            },
            'max' => {
                date    => $now->plus_time_interval('5y'),
                message => 'Exclude time cannot be for more than five years.'
            });

        _validate_date_field(
            $form_self_exclusion,
            'TIMEOUTUNTIL',
            'min' => {
                date    => $now->plus_time_interval('1d')->truncate_to_day,
                message => 'Timeout time must be greater than current time.'
            },
            'max' => {
                date    => $now->plus_time_interval('42d'),              # 6*7 days
                message => 'Timeout time cannot be more than 6 weeks.'
            });

        if ($max_deposit_expiry xor $max_deposit) {
            $form_self_exclusion->set_field_error_message($max_deposit ? 'MAXDEPOSIT' : 'MAXDEPOSITDATE',
                "Max deposit and Max deposit end date must be set together.");
        }

        _validate_date_field(
            $form_self_exclusion,
            'MAXDEPOSITDATE',
            'min' => {
                date    => $now->plus_time_interval('1d')->truncate_to_day,
                message => 'The expiry date must be greater than current time.'
            });
    };

    $form_self_exclusion->set_server_side_checks($server_side_validation_sub);
    return $form_self_exclusion;
}

=head2 _validate_date_field

Taking a filed name with date type, checks if it's a valid date and lies between minimum and maximum limits. It takes folliwing args:

=over

=item *  C<form> - L<HTML::FormBuilder::Validation> represents an HTML form

=item * C<field_id> - the HTML id of the field to be validated

=item * C<limits> - (optional) a hash representing C<min> and C<max> limits, each with following properties:

=over

=item * C<value> - L<Date::Utility> a datetime object against which the field's value will be compared

=item * C<message> - an error message to be displayed if the limit is crossed

=back

=back

=cut

sub _validate_date_field {
    my ($form, $field_id, %limits) = @_;
    my $text_value = $form->get_field_value($field_id);

    return if not $text_value or $form->is_error_found_in($field_id);

    my $date_value = eval { Date::Utility->new($text_value) };

    unless ($date_value) {
        $form->set_field_error_message($field_id, "Invalid date value $text_value.");
        return;
    }

    if ($limits{min} and $date_value->is_before($limits{min}->{date})) {
        $form->set_field_error_message($field_id, $limits{min}->{message});
        return;
    }

    if ($limits{max} and $date_value->is_after($limits{max}->{date})) {
        $form->set_field_error_message($field_id, $limits{max}->{message});
        return;
    }
}

sub get_payment_agent_registration_form {
    my $params             = shift;
    my $loginid            = $params->{loginid};
    my $brokercode         = $params->{brokercode};
    my $coc_approval_time  = $params->{coc_approval_time};
    my $allowable_services = $params->{allowable_services};

    # input field for pa_name
    my $input_field_pa_name = {
        'label' => {
            'text' => 'Your name/company',
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
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^.{1,60}$',
                'err_msg' => 'Please enter a valid name.',
            },
        ]};

    my $input_field_risk_level = {
        'label' => {
            'text' => 'Risk Level',
            'for'  => 'pa_risk_level'
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_risk_level',
            'name'    => 'pa_risk_level',
            'options' => [{
                    value => 'low',
                    text  => 'Low'
                },
                {
                    value => 'standard',
                    text  => 'Standard'
                },
                {
                    value => 'high',
                    text  => 'High',
                },
                {
                    value => 'manual override - low',
                    text  => 'Manual override - Low'
                },
                {
                    value => 'manual override - standard',
                    text  => 'Manual override - Standard'
                },
                {
                    value => 'manual override - high',
                    text  => 'Manual override - High',
                }])};

    my $input_field_pa_coc_approval = {
        'label' => {
            'text' => 'Code of conduct approval' . ($coc_approval_time ? " <br/> (approved on $coc_approval_time)" : ''),
            'for'  => 'pa_coc_approval'
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_coc_approval',
            'name'    => 'pa_coc_approval',
            'values'  => ['0'],
            'options' => _select_yes_no(),
        )};

    # Input field for pa_email
    my $input_field_pa_email = {
        'label' => {
            'text' => 'Your email address',
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
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => _email_check_regexp(),
                'err_msg' => 'Sorry, you have entered an incorrect email address.',
            },
        ]};

    # input field for pa_tel
    my $input_field_pa_tel = {
        'label' => {
            'text' => 'Your phone number',
            'for'  => 'pa_tel',
        },
        'input' => {
            'id'   => 'pa_tel',
            'name' => 'pa_tel',
            'type' => 'textarea',
            'rows' => 5,
            'cols' => 30,
        },
        'error' => {
            'id'    => 'errorpa_tel',
            'class' => 'error',
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(|\+?[0-9\s\-]+\n*)*(|\+?[0-9\s\-]+)$',
                'err_msg' => 'Invalid telephone number.',
            },
            # max length = 20
            {
                'type'    => 'regexp',
                'regexp'  => '^(\+[\-\ 0-9]{8,20}(\n|$))+$',
                'err_msg' => 'Invalid telephone number (it should consist of 8 to 20 characters).',
            }
        ],
        comment => {
            'text' => '** One phone number per line.',
        }};

    # input field for pa_url
    my $input_field_pa_url = {
        'label' => {
            'text' => 'Your website URL(s)',
            'for'  => 'pa_url'
        },
        'input' => {
            'id'   => 'pa_url',
            'name' => 'pa_url',
            'type' => 'textarea',
            'rows' => 5,
            'cols' => 30,
        },
        'error' => {
            'id'    => 'errorpa_url',
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(https?:\/\/[^\s\n]+\n)*https?:\/\/[^\s\n]+$',
                'err_msg' => 'This URL is invalid.',
            },
        ],
        comment => {
            'text' => '** One URL per line.',
        }};

    # input field for pa_comm_depo
    my $input_field_pa_comm_depo = {
        'label' => {
            'text' => 'Commission (%) you want to take on deposits',
            'for'  => 'pa_comm_depo',
        },
        'input' => {
            'id'        => 'pa_comm_depo',
            'name'      => 'pa_comm_depo',
            'type'      => 'text',
            'maxlength' => 4,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^[0-9](\.[0-9]{1,2})?$',
                'err_msg' => 'Commission must be between 0 to 9 with at most two decimal digits',
            },
            {
                'type'    => 'max_amount',
                'amount'  => 9,
                'err_msg' => 'Commission cannot be more than 9',
            },
        ],
        'error' => {
            'id'    => 'errorpa_comm_depo',
            'class' => 'error'
        },
    };

    # input field for pa_comm_with
    my $input_field_pa_comm_with = {
        'label' => {
            'text' => 'Commission (%) you want to take on withdrawals',
            'for'  => 'pa_comm_with',
        },
        'input' => {
            'id'        => 'pa_comm_with',
            'name'      => 'pa_comm_with',
            'type'      => 'text',
            'maxlength' => 4,
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^[0-9](\.[0-9]{1,2})?$',
                'err_msg' => 'Commission must be between 0 to 9 with at most two decimal digits',
            },
            {
                'type'    => 'max_amount',
                'amount'  => 9,
                'err_msg' => 'Commission cannot be more than 9',
            },
        ],
        'error' => {
            'id'    => 'errorpa_comm_with',
            'class' => 'error'
        },
    };

    my $input_field_pa_max_withdrawal = {
        'label' => {
            'text' => 'Max withdrawal limit',
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
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(?![+-])(?:[1-9][0-9]*|0)?(?:\.[0-9]+)?$',
                'err_msg' => 'Please enter a positive numeric value.',
            },
        ],
    };

    my $input_field_pa_min_withdrawal = {
        'label' => {
            'text' => 'Min withdrawal limit',
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
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(?![+-])(?:[1-9][0-9]*|0)?(?:\.[0-9]+)?$',
                'err_msg' => 'Please enter a positive numeric value.',
            },
        ],
    };

    # Input field for pa_info
    my $textarea_pa_info = {
        'label' => {
            'text' => 'Please provide some information about yourself and your proposed services',
            'for'  => 'pa_info',
        },
        'input' => {
            'id'      => 'pa_info',
            'name'    => 'pa_info',
            'type'    => 'textarea',
            'rows'    => 5,
            'cols'    => 60,
            'maxsize' => '500',
        },
        'error' => {
            'text'  => '',
            'id'    => 'errorpa_info',
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^(.|\n){0,500}$',
                'err_msg' => 'Comment must not exceed 500 characters. Please resubmit.',
            },

        ],
    };

    # Input field for pa_supported_payment_method
    my $input_field_pa_supported_payment_method = {
        'label' => {
            'text' => 'Supported Payment Methods',
            'for'  => 'pa_supported_payment_method'
        },
        'input' => {
            'id'   => 'pa_supported_payment_method',
            'name' => 'pa_supported_payment_method',
            'type' => 'textarea',
            'rows' => 5,
            'cols' => 30,
        },
        'error' => {
            'id'    => 'errorpa_suported_payment_method',
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^[\w \-\n]{2,500}$',
                'err_msg' => 'Supported payment methods must be between 2 and 500 characters (only latin alphabets, space and comma).',
            },
        ],
        comment => {
            'text' => '** One payment method per line.',
        }};

    # Input field for pa_auth
    my $input_field_pa_status = {
        'label' => {
            'text' => 'PAYMENT AGENT STATUS',
            'for'  => 'pa_status',
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_status',
            'name'    => 'pa_status',
            'values'  => ['0'],
            'options' => [{
                    value => '',
                    text  => 'Please select'
                },
                {
                    value => 'applied',
                    text  => 'Applied'
                },
                {
                    value => 'verified',
                    text  => 'Verified'
                },
                {
                    value => 'authorized',
                    text  => 'Authorized'
                },
                {
                    value => 'suspended',
                    text  => 'Suspended'
                },
                {
                    value => 'rejected',
                    text  => 'Rejected'
                },
            ],
        )};

    my $input_field_pa_status_comments = {
        'label' => {
            'text' => 'Status comments',
            'for'  => 'pa_status_comment',
        },
        'input' => {
            'id'        => 'pa_status_comment',
            'name'      => 'pa_status_comment',
            'type'      => 'text',
            'maxlength' => 500,
        }};

    # Input field for pa_listed
    my $input_field_pa_listed = {
        'label' => {
            'text' => 'LISTED PAYMENT AGENT?',
            'for'  => 'pa_listed'
        },
        'input' => HTML::FormBuilder::Select->new(
            'id'      => 'pa_listed',
            'name'    => 'pa_listed',
            'values'  => ['0'],
            'options' => _select_yes_no(),
        )};

    # Input field for pa_countries
    my $input_field_pa_countries = {
        'label' => {
            'text' => 'Countries',
            'for'  => 'pa_countries'
        },
        'input' => {
            'id'        => 'pa_countries',
            'name'      => 'pa_countries',
            'type'      => 'text',
            'maxlength' => 500,
        },
        'error' => {
            'id'    => 'errorpa_countries',
            'class' => 'error'
        },
        'validation' => [{
                'type'    => 'regexp',
                'regexp'  => '^[a-zA-Z,]*$',
                'err_msg' => 'Countries list is invalid',
            },
        ],
        comment => {
            'text' => '** Comma-separated list of 2 character country code (no spaces) e. g id,vn',
        }};

    # input field for pa_affiliate_id
    my $input_field_pa_affiliate_id = {
        'label' => {
            'text' => 'Affiliate id (if exists)',
            'for'  => 'pa_affiliate_id'
        },
        'input' => {
            'id'        => 'pa_affiliate_id',
            'name'      => 'pa_affiliate_id',
            'type'      => 'text',
            'maxlength' => 60,
        },
        'error' => {
            'id'    => 'errorpa_affiliate_id',
            'class' => 'errorfield'
        },
    };

    my $label_services_allowed = {
        'label' => {
            'text' => 'RESTRICTED SERVICES ALLOWED:',
        }};

    my @input_fields_services_allowed;
    for my $service ($allowable_services->@*) {
        push @input_fields_services_allowed,
            {
            'label' => {
                'text' => "&nbsp;" x 10 . $service,
                'for'  => "pa_services_allowed_$service",
            },
            'input' => HTML::FormBuilder::Select->new(
                'id'      => "pa_services_allowed_$service",
                'name'    => "pa_services_allowed_$service",
                'values'  => ['0'],
                'options' => _select_yes_no(),
            )};

    }
    my $input_field_pa_serices_allowed_comments = {
        'label' => {
            'text' => 'Services Allowed Comments',
            'for'  => 'pa_services_allowed_comments',
        },
        'input' => {
            'id'        => 'pa_services_allowed_comments',
            'name'      => 'pa_services_allowed_comments',
            'type'      => 'text',
            'maxlength' => 500,
        }};

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
            'value' => 'Submit',
            'class' => 'btn btn--primary',
        }};

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
    $fieldset->add_field($input_field_risk_level);
    $fieldset->add_field($input_field_pa_url);
    $fieldset->add_field($input_field_pa_email);
    $fieldset->add_field($input_field_pa_tel);
    $fieldset->add_field($textarea_pa_info);
    if ($input_field_pa_supported_payment_method) {
        $fieldset->add_field($input_field_pa_supported_payment_method);
    }
    $fieldset->add_field($input_field_pa_comm_depo);
    $fieldset->add_field($input_field_pa_comm_with);
    $fieldset->add_field($input_field_pa_min_withdrawal);
    $fieldset->add_field($input_field_pa_max_withdrawal);
    $fieldset->add_field($input_field_pa_affiliate_id);
    $fieldset->add_field($input_field_pa_coc_approval);
    if ($input_field_pa_status) {
        $fieldset->add_field($input_field_pa_status);
    }
    if ($input_field_pa_status_comments) {
        $fieldset->add_field($input_field_pa_status_comments);
    }
    if ($input_field_pa_listed) {
        $fieldset->add_field($input_field_pa_listed);
    }
    $fieldset->add_field($input_field_pa_countries);

    $fieldset->add_field($label_services_allowed);
    $fieldset->add_field($_) for @input_fields_services_allowed;
    $fieldset->add_field($input_field_pa_serices_allowed_comments);

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
            text  => 'Please select'
        },
        {
            value => 'yes',
            text  => 'Yes'
        },
        {
            value => 'no',
            text  => 'No',
        }];
}

sub _email_check_regexp {
    return '^([a-zA-Z0-9_.+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4})?$';
}

=head2 get_csrf_token

Returns the generated CSRF token to be used in forms.

=cut

sub get_csrf_token {
    my $auth_token = request()->cookies->{auth_token};

    die "Can't find auth token" unless $auth_token;

    return sha256_hex(SALT_FOR_CSRF_TOKEN . $auth_token);
}

1;

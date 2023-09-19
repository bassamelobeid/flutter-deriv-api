package BOM::User::FinancialAssessment;

use strict;
use warnings;

use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Context qw (request);
use BOM::Platform::Email   qw(send_email);
use BOM::Config;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util      qw/none all any/;

use feature "state";

use base qw (Exporter);

use constant ONE_DAY                                  => 86400;                                           # In seconds
use constant APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD => 'APPROPRIATENESS_TESTS::COOLING_OFF_PERIOD::';
our @EXPORT_OK = qw(update_financial_assessment build_financial_assessment is_section_complete decode_fa
    should_warn format_to_new appropriateness_tests calculate_cfd_score APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD copy_financial_assessment);

my $config = BOM::Config::financial_assessment_fields();

=head2 update_financial_assessment

Given a user and a hashref of the financial assessment does the following :
    - updates that user's financial assessment
    - sends a corresponding email to compliance with the fields and the score evaluation of said fields

=cut

sub update_financial_assessment {
    my ($user, $args, %options) = @_;
    my $is_new_mf_client = $options{new_mf_client} // 0;
    # Doesn't matter which client we get as they all share the same financial assessment details
    my @all_clients = $user->clients();

    my $client = $all_clients[0];
    return undef if $client->landing_company->is_suspended;

    my $previous = $client->financial_assessment();
    $previous = decode_fa($previous) if $previous;

    my $filtered_args = +{map { $_ => $args->{$_} } grep { $args->{$_} } @{_financial_assessment_keys()}};

    my $data_to_be_saved;
    $data_to_be_saved = {%$previous} if $previous;

    foreach my $key (keys %$filtered_args) {
        $data_to_be_saved->{$key} = $filtered_args->{$key};
    }
    # We need to update Financial Assessment data for each client.
    foreach my $cli (@all_clients) {

        $cli->financial_assessment({data => encode_json_utf8($data_to_be_saved)});

        if (    $cli->status->mt5_withdrawal_locked
            and $cli->status->mt5_withdrawal_locked->{'reason'} =~ /FA is required for the first deposit on regulated MT5./g)
        {
            $cli->status->clear_mt5_withdrawal_locked;
        }
        $cli->save;

    }

    $client->update_status_after_auth_fa();

    # Emails are sent for:
    # - Non-CR clients
    # - High risk CR with MT5 accounts
    my @client_ids = $user->loginids();
    if (my @cr_clients = $user->clients_for_landing_company('svg')) {
        # should we include CR clients since Sr applies on them also now
        return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client, $client->landing_company->short)
            if ($client->risk_level_sr() eq 'high')
            || ((any { $_ =~ /^MT[DR]?/ } @client_ids)
            && (any { $_->risk_level_aml() eq 'high' } @cr_clients));
    } else {
        return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client, $client->landing_company->short);
    }

    return undef;
}

# Email to compliance, based on updates on financial assessment
sub _email_diffs_to_compliance {
    my ($previous, $new, $client_ids, $is_new_mf_client, $landing_company) = @_;
    if ($landing_company eq 'maltainvest') {
        $new->{calculate_appropriateness} = 1;
    }

    $new = build_financial_assessment($new);
    my $subj_ids = join ", ", grep { $_ !~ /^(?:VR|MT[DR]?)/ } @$client_ids;
    my ($content, $subject, $message);
    foreach my $section (keys %$new) {
        next if $section eq "scores";
        my $title = join " ", map { ucfirst($_) } split('_', $section);
        $content->{sections}->{$section} =
              "<h1>$title</h1>\n"
            . '<table border="1" cellpadding="5" style="border-collapse:collapse">'
            . "<tr><th> Question </th><th> Previous Answer </th><th> New Answer </th></tr>\n";

        foreach my $key (keys %{$new->{$section}}) {
            my $key_obj         = $new->{$section}->{$key};
            my $previous_answer = $previous->{$key} // "N/A";
            my $current_answer  = $key_obj->{answer} && $key_obj->{answer} eq $previous_answer ? "N/A" : $key_obj->{answer} // "N/A";
            $content->{$section} = 1 if defined $key_obj->{answer} && $current_answer ne "N/A";
            $content->{sections}->{$section} .= "<tr><td> $key_obj->{label} </td><td> $previous_answer </td><td> $current_answer </td></tr>\n";
        }
        $content->{sections}->{$section} .= "\n</table>";
    }
    my $brand = request()->brand;

    # send seperate emails for financial assessment
    my $to_email = $brand->emails('compliance_ops');

    if ($content->{financial_information}) {
        $subject = sprintf "%s has %s the financial assessment", $subj_ids, $is_new_mf_client ? "submitted" : "updated";
        $message = $content->{sections}->{financial_information};

        send_email({
            from                  => $brand->emails('support'),
            to                    => $to_email,
            subject               => $subject,
            message               => [$message],
            email_content_is_html => 1
        });
    }
    if ($content->{trading_experience} || $content->{trading_experience_regulated}) {
        $subject = sprintf "%s has %s the trading assessment", $subj_ids, $is_new_mf_client ? "submitted" : "updated";
        $message = $content->{trading_experience} ? $content->{sections}->{trading_experience} : "";

        if ($landing_company eq 'maltainvest') {
            $message .= $content->{sections}->{trading_experience_regulated} // "" if $content->{trading_experience_regulated};
            if ($new->{scores}->{trading_experience_regulated} == 0) {
                $message .= '<h3>Result: Client accepted financial risk disclosure</h3>';
            } else {
                $message .= '<h3>Result: Financial risk approved based on trading assessment score</h3>';
            }
        }
        send_email({
            from                  => $brand->emails('support'),
            to                    => $to_email,
            subject               => $subject,
            message               => [$message],
            email_content_is_html => 1
        });
    }

    return;
}

=head2 build_financial_assessment

Takes in raw data (label => answer) and produces evaluated structured financial assessment output

Two main labels are build: Trading experience and financial information

=cut

sub build_financial_assessment {
    my $raw                       = shift;
    my $section_scores            = delete $raw->{get_section_scores};
    my $calculate_appropriateness = delete $raw->{calculate_appropriateness};
    my $result;
    foreach my $fa_information (keys %$config) {
        foreach my $key (keys %{$config->{$fa_information}}) {

            my $provided_answer  = $raw->{$key};
            my $possible_answers = $config->{$fa_information}->{$key}->{possible_answer};
            my $score            = ($provided_answer && defined $possible_answers->{$provided_answer}) ? $possible_answers->{$provided_answer} : 0;
            my $section          = $config->{$fa_information}->{$key}->{section};
            $result->{$fa_information}->{$key}->{label}  = $config->{$fa_information}->{$key}->{label};
            $result->{$fa_information}->{$key}->{answer} = $provided_answer;
            $result->{$fa_information}->{$key}->{score}  = $score;

            #the score of financial_information_regulated will be the duplicated so should be removed
            $result->{scores}->{$fa_information} += $score unless $fa_information =~ /financial_information_regulated/;
            $result->{scores}->{total_score}     += $score unless $fa_information =~ /financial_information_regulated/;
            $result->{scores}->{cfd_score}       += $score if $key =~ /cfd_trading_frequency|cfd_trading_experience|cfd_frequency|cfd_experience/;
            if ($section && ($section_scores || $calculate_appropriateness)) {
                $result->{scores}->{appropriateness}->{$section} += $score;
            }
        }
    }

    #client failed the appropriateness test, his trading score is set to zero
    if (   $calculate_appropriateness
        && exists $result->{scores}->{appropriateness}
        && exists $result->{scores}->{trading_experience_regulated})
    {
        if (!_calculate_appropriateness_sections($result->{scores}->{appropriateness})) {
            $result->{scores}->{trading_experience_regulated} = 0;
        }
        delete $result->{scores}->{appropriateness};
    }
    return $result;
}

sub _financial_assessment_keys {
    my $should_split = shift;

    return +{map { $_ => [keys %{$config->{$_}}] } keys %$config} if $should_split;
    return [map { keys %$_ } values %$config];
}

=head2 is_section_complete

Checks whether the required section of financial assessment has been completed

=cut

sub is_section_complete {
    my $fa      = shift;
    my $section = shift;
    my $lc      = shift // '';
    $section .= "_regulated" if ($lc eq 'maltainvest');
    my $result =
        0 + all { $fa->{$_} && defined $config->{$section}->{$_}->{possible_answer}->{$fa->{$_}} } @{_financial_assessment_keys(1)->{$section}};
    # check legacy cfd_score
    if ($section eq 'trading_experience_regulated' && !$result) {
        my $cfd_score = 0;
        $section = 'trading_experience';
        my $old_result =
            0 + all { $fa->{$_} && defined $config->{$section}->{$_}->{possible_answer}->{$fa->{$_}} } @{_financial_assessment_keys(1)->{$section}};
        for my $k (qw(cfd_trading_frequency cfd_trading_experience)) {
            $cfd_score += $config->{$section}{$k}{possible_answer}{$fa->{$k}} if $fa->{$k};
        }
        return $cfd_score > 0 && $old_result ? 1 : 0;
    }
    return $result;
}

sub decode_fa {
    my $fa = shift;

    return {} unless $fa;

    $fa = $fa->data ? decode_json_utf8($fa->data) : {};

    return $fa;
}

=head2 should_warn

Show the Risk Disclosure warning message when the trading score is less than 8 or CFD score is less than 4

=cut

sub should_warn {
    my $fa = shift;
    # Only parse if it's not already parsed
    $fa->{get_section_scores} = 1;
    $fa = $fa->{scores} ? $fa : build_financial_assessment($fa);
    my $scores = $fa->{scores};

    my $cfd_score_warn = $scores->{cfd_score} && $scores->{cfd_score} >= 4;

    my $trading_score_warn = 0;
    if ($fa->{scores}->{appropriateness}) {
        $trading_score_warn = _calculate_appropriateness_sections($fa->{scores}->{appropriateness});
    } else {
        $trading_score_warn = $scores->{trading_experience} && ($scores->{trading_experience} >= 8 && $scores->{trading_experience} <= 16);
    }

    return 0 if $cfd_score_warn || $trading_score_warn;

    return 1;
}

=head2 appropriateness_tests

calculates appropriateness test criteria for maltainvest

=over 4

=item * C<$client> - the client object

=item * C<$args> - the raw data for trading experience

=back

returns a hash ref 

sets a cooldown period(1day) if client failed the new maltainvest tests and have not accepted the risk

{
 result                      => test result (1 || 0),
 cooling_off_expiration_date => date in epoch format on which a new account can be created if tests failed;
}

=cut

sub appropriateness_tests {
    my ($client, $args) = @_;
    my $redis                  = BOM::Config::Redis::redis_replicated_write();
    my $binary_user_id         = $client->{binary_user_id};
    my $cooling_off_period_ttl = $redis->ttl(APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD . $binary_user_id);
    if ($cooling_off_period_ttl > 0) {
        return {
            result                      => 0,
            cooling_off_expiration_date => Date::Utility->new()->plus_time_interval($cooling_off_period_ttl . 's')->epoch
        };
    } else {
        $client->status->clear_cooling_off_period;
    }

    $args->{get_section_scores} = 1;

    my $structure = build_financial_assessment($args);
    my $scores    = $structure->{scores}->{appropriateness};

    my $result = _calculate_appropriateness_sections($scores);
    # Only Put a lock on the account if the use have failed and not accepted the risk check or failed the first question
    if (!$result) {
        if (!$scores || !$scores->{1} || (defined $args->{accept_risk} && !$args->{accept_risk})) {
            # Set cooling_off_period status
            $redis->setex(APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD . $binary_user_id, ONE_DAY, 'cooling_off_period');
            my $cooling_off_expiration_date = Date::Utility->new()->plus_time_interval(ONE_DAY);
            $client->status->setnx('cooling_off_period', 'system',
                'APPROPRIATENESS_TESTS::COOLING_OFF_EXPIRATION_DATE::' . $cooling_off_expiration_date->datetime_ddmmmyy_hhmmss_TZ,
            );
            return {
                result                      => $result,
                cooling_off_expiration_date => $cooling_off_expiration_date->epoch
            };
        }

        if ($args->{accept_risk}) {
            return {result => 1};
        }

    }
    return {result => $result};
}

=head2 _calculate_appropriateness_sections

calculate appropriateness tests sections

=over 4

=item * C<$section_scores> - the scores of each section

=back

If the client FAILS Section 1, return 0.

If clients PASS all sections or fail 1 section (from Section 2, 3 , 4 or 5) success.

Sections 3 and 4 are made of 2 question each and have 2 answer both correctly

Section 4 is made of 4 questions and the client have 2 answer at least 2 correctly

=cut

sub _calculate_appropriateness_sections {
    my $section_scores    = shift;
    my $question_scores   = 0;
    my $sub_section_score = 0;
    my $result;
    if ($section_scores) {
        $result->{group_1} = $section_scores->{1} ? 1 : 0;
        if ($section_scores->{2}) {
            $question_scores += 1;
        }
        #this is considered as 1 section as a whole and 1 point should be added for it only
        if ($section_scores->{3} && $section_scores->{3} > 1) {
            $sub_section_score += 1;
        }
        if ($section_scores->{4} && $section_scores->{4} > 1) {
            $sub_section_score += 1;
        }
        if ($sub_section_score) {
            $question_scores += 1;
        }
        if ($section_scores->{5} && $section_scores->{5} > 1) {
            $question_scores += 1;
        }

        #If clients PASS at least 2 sections or fail 1 section (from Section 2, 3, 4 or 5 - 3 and 3 are considered the same section
        $result->{group_2} = $question_scores > 1                     ? 1 : 0;
        $result->{final}   = $result->{group_1} && $result->{group_2} ? 1 : 0;
    }
    return $result->{final};
}

=head2 copy_financial_assessment

Copies the financial assessment info from one client to another.

It takes the following arguments as hashref keys:

=over 4

=item * C<from> - the client whose financial assessment info will be copied from

=item * C<to> - the client that will get the financial assessment info

=back

Returns undef.

=cut

sub copy_financial_assessment {
    my ($from, $to) = @_;

    my $fa = $from->financial_assessment();

    if ($fa) {
        $fa = decode_fa($fa);

        $to->financial_assessment({data => encode_json_utf8($fa)});
        $to->save;
        $to->update_status_after_auth_fa();
    }

    return undef;
}

1;

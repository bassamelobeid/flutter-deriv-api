package BOM::User::FinancialAssessment;

use strict;
use warnings;

use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Context qw (request);
use BOM::Platform::Email qw(send_email);
use BOM::Config;
use BOM::Config::RedisReplicated;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util qw/none all any/;

use feature "state";

use base qw (Exporter);
our @EXPORT_OK =
    qw(update_financial_assessment build_financial_assessment is_section_complete decode_fa decode_obsolete_data should_warn get_section format_to_new);

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
        $cli->save;
    }

    # Clear unwelcome status for clients without financial assessment and have breached
    # social responsibility thresholds
    if ($client->landing_company->social_responsibility_check_required && $client->status->unwelcome) {
        my $redis    = BOM::Config::RedisReplicated::redis_events_write();
        my $key_name = $client->loginid . '_sr_risk_status';
        
        $client->status->clear_unwelcome if $redis->get($key_name);
    }

    # Emails are sent for:
    # - Non-CR clients
    # - High risk CR with MT5 accounts
    my @client_ids = $user->loginids();
    if (my @cr_clients = $user->clients_for_landing_company('svg')) {

        return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client)
            if ((any { $_ =~ /^MT/ } @client_ids) && (any { $_->risk_level() eq 'high' } @cr_clients));
    } else {
        return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client);
    }

    return undef;
}

# Email to compliance, based on updates on financial assessment
sub _email_diffs_to_compliance {
    my ($previous, $new, $client_ids, $is_new_mf_client) = @_;

    my $message;
    $new = build_financial_assessment($new);
    my $subject = join ", ", grep { $_ !~ /^VR|MT/ } @$client_ids;

    if (keys %$previous && !$is_new_mf_client) {
        my $diffs = _build_diffs($new, $previous);

        foreach my $key (keys %$diffs) {

            $message .= "$key : " . $diffs->{$key}->[0] . "  ->  " . $diffs->{$key}->[1] . "\n";
        }

        $subject .= ' assessment test details have been updated';

    } elsif ($is_new_mf_client) {

        foreach my $section (keys %$new) {

            next if $section eq "scores";

            foreach my $key (keys %{$new->{$section}}) {
                my $key_obj = $new->{$section}->{$key};
                next unless $key_obj->{answer};

                $message .= "$key_obj->{label} : $key_obj->{answer}\n";
            }
        }

        $subject .= " has submitted the assessment test";
    }

    return undef unless $message;

    $message .= "\nTotal Score :  " . $new->{scores}->{total_score} . "\n";
    $message .= "Trading Experience Score :  " . $new->{scores}->{trading_experience} . "\n";
    $message .= "CFD Score :  " . $new->{scores}->{cfd_score} . "\n";
    $message .= "Financial Information Score :  " . $new->{scores}->{financial_information};

    if ($is_new_mf_client) {
        # If it has gotten to this point with should_warn being true, the client would already have had to accept the risk disclosure
        $message .= "\n\nThe Risk Disclosure was ";
        $message .= should_warn($new) ? "shown and client accepted the disclosure." : "not shown.";
    }

    my $brand = request()->brand;
    return send_email({
        from    => $brand->emails('support'),
        to      => $brand->emails('compliance'),
        subject => $subject,
        message => [$message],
    });
}

=head2 _build_diffs

Takes in a built FA (from client-side) and an unbuilt one (from database) and returns their differences in a hash containing arrays

=cut

sub _build_diffs {
    my ($new, $previous) = @_;
    my $diffs;

    for my $sect (sort keys %$new) {

        # Score are not used in finding the difference in Financial Assessment data
        next if $sect eq 'scores';

        for my $key (sort keys %{$new->{$sect}}) {

            my $new_answer = $new->{$sect}->{$key}->{answer};
            next unless $new_answer;

            my $previous_answer = $previous->{$key};

            unless ($previous_answer) {
                $previous_answer = "N/A";
            } elsif ($previous_answer eq $new_answer) {
                next;
            }

            $diffs->{$new->{$sect}->{$key}->{label}} = [$previous_answer, $new_answer];
        }
    }

    return $diffs;
}

=head2 build_financial_assessment

Takes in raw data (label => answer) and produces evaluated structured financial assessment output

Two main labels are build: Trading experience and financial information

=cut

sub build_financial_assessment {
    my $raw = shift;

    my $result;

    foreach my $fa_information (keys %$config) {
        foreach my $key (keys %{$config->{$fa_information}}) {

            my $provided_answer  = $raw->{$key};
            my $possible_answers = $config->{$fa_information}->{$key}->{possible_answer};
            my $score            = ($provided_answer && defined $possible_answers->{$provided_answer}) ? $possible_answers->{$provided_answer} : 0;

            $result->{$fa_information}->{$key}->{label}  = $config->{$fa_information}->{$key}->{label};
            $result->{$fa_information}->{$key}->{answer} = $provided_answer;
            $result->{$fa_information}->{$key}->{score}  = $score;

            $result->{scores}->{$fa_information} += $score;
            $result->{scores}->{total_score} += $score;
            $result->{scores}->{cfd_score} += $score if $key eq 'cfd_trading_frequency' or $key eq 'cfd_trading_experience';
        }
    }

    return $result;
}

sub _financial_assessment_keys {
    my $should_split = shift;

    return +{map { $_ => [keys %{$config->{$_}}] } keys %$config} if $should_split;
    return [map { keys %$_ } values %$config];
}

sub is_section_complete {
    my $fa      = shift;
    my $section = shift;

    return 0 + all {
        $fa->{$_} && defined $config->{$section}->{$_}->{possible_answer}->{$fa->{$_}}
    }
    @{_financial_assessment_keys(1)->{$section}};
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
    $fa = $fa->{scores} ? $fa : build_financial_assessment($fa);
    my $scores = $fa->{scores};

    my $cfd_score_warn = $scores->{cfd_score} >= 4;
    my $trading_score_warn = ($scores->{trading_experience} >= 8 && $scores->{trading_experience} <= 16);

    return 0 if $cfd_score_warn || $trading_score_warn;

    return 1;
}

1;

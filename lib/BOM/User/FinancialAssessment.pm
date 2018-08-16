package BOM::User::FinancialAssessment;

use strict;
use warnings;

use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Context qw (request);
use BOM::Platform::Email qw(send_email);
use Brands;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use YAML::XS;
use List::Util qw/none all any/;
use Array::Utils qw/array_minus/;

use feature "state";

use base qw (Exporter);
our @EXPORT_OK =
    qw(update_financial_assessment get_config build_financial_assessment is_section_complete decode_fa decode_obsolete_data should_warn get_section format_to_new);

=head2 update_financial_assessment

Given a user and a hashref of the financial assessment does the following :
    - updates that user's financial assessment
    - sends a corresponding email to compliance with the fields and the score evaluation of said fields

=cut

sub update_financial_assessment {
    my ($user, $args, %options) = @_;
    my $is_new_mf_client = $options{new_mf_client} // 0;

    # Doesn't matter which client we get as they all share the same financial assessment details. Will be changed when we move financial assessment data from client level to user level
    my @all_clients = $user->clients();
    my $previous    = $all_clients[0]->financial_assessment();
    $previous = decode_fa($previous) if $previous;

    # We need to update Financial Assessment data for each client. This will change when we move Financial Assessment data from client level to user level.
    my $filtered_args = _filter_relevant_keys($args);

    my $data_to_be_saved;
    $data_to_be_saved = {%$previous} if $previous;

    foreach my $key (keys %$filtered_args) {
        $data_to_be_saved->{$key} = $filtered_args->{$key};
    }

    foreach my $cli (@all_clients) {    #TODO : change to only save this to the user after userdb change
        $cli->financial_assessment({data => encode_json_utf8($data_to_be_saved)});
        $cli->save;
    }
    my @client_ids = $user->loginids();
    if (my @cr_clients = $user->clients_for_landing_company('costarica')) {
        if (   (any { $_->aml_risk_level eq 'high' } @cr_clients)
            && (any { $_ =~ /^MT/ } @client_ids))    # TODO : Change MT5 check to mt5_logins when that is changed not to hit MT5's servers
        {
            return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client);
        }
    } else {                                         # if the user falls under any other landing company
        return _email_diffs_to_compliance($previous, $args, \@client_ids, $is_new_mf_client);
    }
}

# Given the previous and the new financial assessment data, parses the changes made and email said changes to compliance.
sub _email_diffs_to_compliance {
    my ($previous, $new, $client_ids, $is_new_mf_client) = @_;
    my $message;
    my $brand = Brands->new(name => request()->brand);
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
            if ($section ne "scores") {
                foreach my $key (keys %{$new->{$section}}) {
                    my $key_obj = $new->{$section}->{$key};
                    $message .= "$key_obj->{label} : $key_obj->{answer}\n" if $key_obj->{answer};
                }
            }
        }

        $subject .= " has submitted the assessment test";
    }

    return undef unless $message;

    $message .= "\nTotal Score :  " . $new->{scores}->{total_score} . "\n";
    $message .= "Trading Experience Score :  " . $new->{scores}->{trading_score} . "\n";
    $message .= "CFD Score :  " . $new->{scores}->{cfd_score} . "\n";
    $message .= "Financial Information Score :  " . $new->{scores}->{financial_information_score};

    if ($is_new_mf_client) {
        # If it has gotten to this point with should_warn being true, the client would already have had to accept the risk disclosure
        $message .= "\n\nThe Risk Disclosure was ";
        $message .= should_warn($new) ? "shown and client accepted the disclosure." : "not shown.";
    }

    return send_email({
        from    => $brand->emails('support'),
        to      => $brand->emails('compliance'),
        subject => $subject,
        message => [$message],
    });
}

# Takes in a built FA (using build_financial_assessment) and an unbuilt one and returns their differences in a hash containing arrays
sub _build_diffs {
    my ($new, $previous) = @_;
    my $diffs;

    for my $sect (sort keys %$new) {
        if ($sect ne 'scores') {    #Score are not used in finding the difference in Financial Assessment data
            for my $key (sort keys %{$new->{$sect}}) {
                if ($new->{$sect}->{$key}->{answer}) {
                    if (!$previous->{$key}) {
                        $diffs->{$new->{$sect}->{$key}->{label}} = ["N/A", $new->{$sect}->{$key}->{answer}];
                    } elsif ($previous->{$key} ne $new->{$sect}->{$key}->{answer}) {
                        $diffs->{$new->{$sect}->{$key}->{label}} = [$previous->{$key}, $new->{$sect}->{$key}->{answer}];
                    }
                }
            }
        }
    }

    return $diffs;
}

# This function takes in the old structure of the data stored in the database and formats it to the new structure that is to be applied by an SRP
sub format_to_new {
    my $args = shift;

    return +{map { $_ => $args->{$_}->{answer} } grep { ref $args->{$_} } keys %$args};
}

sub get_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-user/share/financial_assessment_structure.yml');
    return $config;
}

sub _filter_relevant_keys {
    my $args = shift;

    return +{map { $_ => $args->{$_} } grep { $args->{$_} } @{_financial_assessment_keys()}};
}

# Takes in raw data (label => answer) and produces evaluated structured financial assessment output
sub build_financial_assessment {
    my $raw = shift;

    my $config = get_config();
    my $result;

    for my $key (keys %{$config->{financial_information}}) {
        $result->{financial_information}->{$key}->{label}  = $config->{financial_information}->{$key}->{label};
        $result->{financial_information}->{$key}->{answer} = $raw->{$key};

        my $score = $raw->{$key} ? $config->{financial_information}->{$key}->{possible_answer}->{$raw->{$key}} : 0;
        $result->{financial_information}->{$key}->{score} = $score;
        $result->{scores}->{financial_information_score} += $score;
        $result->{scores}->{total_score}                 += $score;
    }

    for my $key (keys %{$config->{trading_experience}}) {
        $result->{trading_experience}->{$key}->{label}  = $config->{trading_experience}->{$key}->{label};
        $result->{trading_experience}->{$key}->{answer} = $raw->{$key};

        my $score = $raw->{$key} ? $config->{trading_experience}->{$key}->{possible_answer}->{$raw->{$key}} : 0;
        $result->{trading_experience}->{$key}->{score} = $score;
        $result->{scores}->{trading_score} += $score;
        $result->{scores}->{cfd_score}     += $score if $key eq 'cfd_trading_frequency' or $key eq 'cfd_trading_experience';
        $result->{scores}->{total_score}   += $score;
    }

    return $result;
}

sub _financial_assessment_keys {
    my $should_split = shift;

    my $config = get_config();
    return +{map { $_ => [keys %{$config->{$_}}] } keys %$config} if $should_split;
    return [map { keys %$_ } values %$config];
}

sub _score_keys {
    return ('trading_score', 'financial_information_score', 'cfd_score', 'total_score');
}

sub is_section_complete {
    my $fa      = shift;
    my $section = shift;

    return 0 + all { $fa->{$_} } @{_financial_assessment_keys(1)->{$section}};
}

# Decodes the raw FA data from the DB. Can take in a section parameter to only return fields relevant to that section (trading_experience or financial_information).
sub decode_fa {
    my $fa  = shift;
    my $key = shift;
    $fa = $fa ? decode_json_utf8($fa->data || '{}') : undef;
    return {} unless $fa;
    # Only the old structure would have an answer object inside a key, will remove when SRP goes through to change all old formats to new
    if (any { ref($fa->{$_}) } keys %$fa) {
        $fa = format_to_new($fa);
    }

    return $fa unless $key;
    return +{map { $_ => $fa->{$_} } grep { $fa->{$_} } @{_financial_assessment_keys(1)->{$key}}};
}

# Show the Risk Disclosure warning message when the trading score is less than 8 or CFD score is less than 4
sub should_warn {
    my $fa = shift;

    # Only parse if it's not already parsed
    $fa = $fa->{scores} ? $fa : build_financial_assessment($fa);

    # No warning when CFD score is 4 or more
    return 0 if $fa->{scores}->{cfd_score} >= 4;

    # No warning when trading score is from 8 to 16
    return 0 if ($fa->{scores}->{trading_score} >= 8 and $fa->{scores}->{trading_score} <= 16);

    return 1;
}

sub get_section {
    my $client  = shift;
    my $section = shift;
    return decode_fa($client->financial_assessment(), $section);
}

1;

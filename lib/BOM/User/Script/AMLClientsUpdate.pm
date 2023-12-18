package BOM::User::Script::AMLClientsUpdate;

use strict;
use warnings;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util      qw(any uniq);
use Syntax::Keyword::Try;
use LandingCompany::Registry;

use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use BOM::Config::Compliance;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);

use Log::Any qw($log);

=head2 new

Class constructor; it's called without any arguments.

=cut

sub new {
    my ($class, %args) = @_;

    my @all_brokers;
    foreach my $landing_company (LandingCompany::Registry->get_all) {
        next
            if $landing_company->is_virtual
            || !($landing_company->risk_lookup->{aml_thresholds} || $landing_company->risk_lookup->{aml_jurisdiction});

        push @all_brokers, $landing_company->broker_codes->@*;
    }
    $args{all_brokers} = [uniq @all_brokers];

    return bless \%args, $class;
}

=head2 client_status_update

Takes the list of recent high risk clients from database, makes them withdrawal locked and 
prepares for POI notificaitons in the front-end.

=cut

sub client_status_update {
    my $self = shift;

    foreach my $broker ($self->{all_brokers}->@*) {
        $self->update_aml_high_risk_clients_status($broker);
    }
}

=head2 aml_risk_update

Updates client aml risk levels based on the configured thresholds.

=cut

sub aml_risk_update {
    my $self = shift;

    my $config       = BOM::Config::Compliance->new;
    my $thresholds   = $config->get_risk_thresholds('aml')          // {};
    my $jurisdiction = $config->get_jurisdiction_risk_rating('aml') // {};

    # filter redundant key 'revision'
    delete $jurisdiction->{revision};
    delete $thresholds->{revision};

    # We should convert landing company names to broker codes in thresholds, because the database function works with broker codes
    for my $short_name (keys %$thresholds) {
        my $lc = LandingCompany::Registry->by_name($short_name);
        next unless $lc;
        $thresholds->{$_} = $thresholds->{$short_name} for $lc->broker_codes->@*;
    }

    my (@jurisdiction_ratings);
    for my $company_name (keys %$jurisdiction) {
        my $landing_company = LandingCompany::Registry->by_name($company_name);
        next unless $landing_company;
        next unless $landing_company->risk_lookup->{aml_jurisdiction};
        next unless $jurisdiction->{$company_name};

        for my $risk_level (qw/standard high/) {
            my $countries = $jurisdiction->{$company_name}->{$risk_level};
            next unless $countries;

            push @jurisdiction_ratings,
                {
                broker    => $_,
                risk      => $risk_level,
                countries => $countries
                } for $landing_company->broker_codes->@*;
        }
    }

    foreach my $broker_code ($self->{all_brokers}->@*) {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code => $broker_code,
            })->db->dbic;

        $dbic->run(
            fixup => sub {
                $_->do("SELECT FROM betonmarkets.update_transaction_risk(?)", undef, encode_json_utf8($thresholds),);
            });

        $dbic->run(
            fixup => sub {
                $_->do("SELECT FROM betonmarkets.update_jurisdiction_risk(?)", undef, encode_json_utf8(\@jurisdiction_ratings),);
            });

        my $result = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref("SELECT * FROM betonmarkets.update_aml_risk()", {Slice => {}},);
            });

        _send_risk_report_email($broker_code, $result) if scalar(@$result);
    }
}

=head2 _send_risk_report_email

Sends an email to the compliance team, containing the list of the recently found high rish clients.

=cut

sub _send_risk_report_email {
    my ($broker_code, $result) = @_;

    my $date = Date::Utility->new->date_yyyymmdd;

    my $content =
          "<h1>Daily AML risk update for $broker_code - $date</h1>\n"
        . '<table border="1" cellpadding="5" style="border-collapse:collapse">'
        . "<tr><th> Operation </th><th> Loginids </th><th> AML Risk Level </th><th> Reason </th></tr>\n";
    for my $row (@$result) {
        try {
            $row->{$_} //= 'low' for (qw/aml_risk_classification deposit jurisdiction/);

            $content .=
                "<tr><td>AML Risk Updated</td><td>$row->{loginids}</td><td>$row->{aml_risk_classification}</td><td>Deposit: $row->{deposit}, Jurisdiction: $row->{jurisdiction}</td></tr>";
        } catch ($e) {
            warn $e;
            $log->errorf("Failed to load user info for AML risk update report: %s", $e);
        }
    }
    $content .= "\n</table>";

    send_email({
        from                  => 'no-reply@deriv.com',
        to                    => 'compliance-alerts@binary.com',
        subject               => "Daily AML risk update - $broker_code",
        message               => [$content],
        use_email_template    => 0,
        email_content_is_html => 1,
        skip_text2html        => 1,
    });
}

=head2 update_aml_high_risk_clients_status

Retrieve a list of clients who have become AML HIGH risk yesterday, who will be added a withdrawal_locked status
unless they are authenticated and completed their financial assessment.

=cut

sub update_aml_high_risk_clients_status {
    my ($class, $landing_company) = @_;

    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => $landing_company,
    });
    my $clientdb = $connection_builder->db->dbic;

    my $recent_high_risk_clients = _get_recent_high_risk_clients($clientdb);
    my @result;

    foreach my $client_info (@$recent_high_risk_clients) {
        my @loginid_list;

        foreach my $client_loginid (split ',', $client_info->{login_ids}) {
            my $client = BOM::User::Client->new({loginid => $client_loginid});

            push @loginid_list, $client_loginid if update_locks_high_risk_change($client);
        }

        if (@loginid_list) {
            $client_info->{login_ids} = join ',', sort(@loginid_list);
            push(@result, $client_info);
        }
    }

    return \@result;
}

=head2 update_locks_high_risk_change

Apply the corresponding locks for a client that becomes AML HIGH risk, depending on the landing company, authentication status
and Financial Assessment completion.

=over 4

=item * C<client> Client instance.

=back

Returns 1 if the corresponding locks are applied or 0 if no locks are needed.

=cut

sub update_locks_high_risk_change {
    my ($client) = @_;

    # filter out clients with fully authenticated status, financial assessment completed and no expired documents
    return 0 if $client->fully_authenticated && $client->is_financial_assessment_complete && !$client->documents->expired;

    if ($client->landing_company->short eq 'maltainvest') {

        # set clients with risk classification = standard for MF accounts
        return 0 if $client->aml_risk_classification ne 'standard';
        $client->status->setnx('withdrawal_locked', 'system', 'FA needs to be completed');

    } else {
        # filter out clients with risk classification = High Risk Override
        return 0 if $client->aml_risk_classification ne 'high';

        $client->status->setnx('withdrawal_locked', 'system', 'Pending authentication or FA');
        $client->status->upsert('allow_document_upload', 'system', 'BECOME_HIGH_RISK');

    }

    return 1;
}

=head2 _get_recent_high_risk_clients

Fetches the recent high risk clients from database, buy running a database funciton.
This function is created to be enable mocking this specific db funciton call, 
because the function fails in circleci due to the included dblink.

=cut

sub _get_recent_high_risk_clients {
    my $clientdb = shift;

    return $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * from betonmarkets.get_recent_high_risk_clients();', {Slice => {}});
        });
}

1

package BOM::User::Script::AMLClientsUpdate;

use strict;
use warnings;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util qw(any);
use Syntax::Keyword::Try;

use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);

use Log::Any qw($log);

use constant BROKER_CODES => (qw/CR MF/);

=head2 new

Class constructor; it's called without any arguments.

=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 client_status_update

Takes the list of recent high risk clients from database, makes them withdrawal locked and 
prepares for POI notificaitons in the front-end.

=cut

sub client_status_update {
    my $self = shift;

    foreach my $broker (BROKER_CODES) {
        $self->update_aml_high_risk_clients_status($broker);
    }
}

=head2 aml_risk_update

Updates client aml risk levels based on the configured thresholds.

=cut

sub aml_risk_update {
    my $self = shift;

    my $thresholds      = BOM::Config::Runtime->instance->app_config->compliance->aml_risk_thresholds;
    my $thresholds_hash = decode_json_utf8($thresholds);
    my @broker_codes    = keys %$thresholds_hash;

    # The DB function accepts thresholds as a json array, rather than a hash.
    my @threshold_array = map { +{broker_code => $_, $thresholds_hash->{$_}->%*} } keys %$thresholds_hash;
    my $threshold_json  = encode_json_utf8(\@threshold_array);

    foreach my $broker_code (@broker_codes) {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code => $broker_code,
            })->db->dbic;

        my $result = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref("SELECT * FROM betonmarkets.update_aml_risk(?)", {Slice => {}}, $threshold_json);
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
        . "<tr><th> Operation </th><th> Loginids </th><th> Reason </th><th> AML Risk Level </th></tr>\n";
    for my $row (@$result) {
        try {
            my $user = BOM::User->new(id => $row->{binary_user_id});
            die "User with id $row->{binary_user_id} was not found" unless $user;

            my $loginids = join ',', $user->loginids;

            $content .= "<tr><td>AML Risk Updated</td><td>$loginids</td><td>$row->{reason}</td><td>$row->{aml_risk_classification}</td></tr>";
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
        my $locked = 0;
        foreach my $client_loginid (split ',', $client_info->{login_ids}) {
            my $client = BOM::User::Client->new({loginid => $client_loginid});

            # filter out authenticated and FA-completed clients
            next if $client->fully_authenticated && $client->is_financial_assessment_complete && !$client->documents->expired;
            # filter out clients with risk classification = High Risk Override
            next if $client->aml_risk_classification ne 'high';

            $client->status->setnx('withdrawal_locked', 'system', 'Pending authentication or FA');
            $client->status->upsert('allow_document_upload', 'system', 'BECOME_HIGH_RISK');

            push @loginid_list, $client_loginid;
            $locked = 1;
        }
        my $client_info->{login_ids} = join ',', sort(@loginid_list);

        push(@result, $client_info) if $locked;
    }

    return \@result;
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

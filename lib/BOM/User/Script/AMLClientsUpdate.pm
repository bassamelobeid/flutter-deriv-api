package BOM::User::Script::AMLClientsUpdate;

use strict;
use warnings;
use BOM::User::Client;
use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use Log::Any qw($log);

sub new {
    my ($class, %args) = @_;
    unless ($args{landing_companies}) {
        return undef;
    }
    return bless \%args, $class;
}

sub run {
    my $self = shift;

    foreach my $landing_company (@{$self->{landing_companies}}) {
        $self->update_aml_high_risk_clients_status($landing_company);
    }
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

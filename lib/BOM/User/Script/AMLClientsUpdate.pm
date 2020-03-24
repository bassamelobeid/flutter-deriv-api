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

        my $result = $self->get_unauthenticated_not_locked_high_risk_clients($landing_company);
        if (@$result) {
            $self->update_aml_high_risk_clients_status($result);
            $self->emit_aml_status_change_event($landing_company, $result);
        }
    }
}

=head2 get_unauthenticated_not_locked_high_risk_clients

Returns a list of clients that become AML Risk High yesterday.

=cut

sub get_unauthenticated_not_locked_high_risk_clients {
    my ($class, $landing_company) = @_;

    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => $landing_company,
    });
    my $clientdb = $connection_builder->db->dbic;

    return $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * from betonmarkets.get_unauthenticated_not_locked_high_risk_clients();', {Slice => {}});
        });
}

=head2 update_aml_high_risk_clients_status

As of now when er detect a client become AML HIGH risk yesterday, we set those 
clients status as withdrawal_locked.

=cut

sub update_aml_high_risk_clients_status {
    my ($class, $aml_updated_clients) = @_;

    return unless ($aml_updated_clients);

    foreach my $client_info (@{$aml_updated_clients}) {
        my @client_login_ids = split(',', $client_info->{login_ids});
        foreach my $client_loginid (@client_login_ids) {
            my $client = BOM::User::Client->new({loginid => $client_loginid});
            $client->status->set('withdrawal_locked',     'system', 'Withdrawal locked due to AML risk become high.');
            $client->status->set('allow_document_upload', 'system', 'Allow document upload due to AML risk become high.');
        }
    }
}

=head2 emit_aml_status_change_event

sends an email to respective department
email will be as per landing company.

=cut

sub emit_aml_status_change_event {
    my ($class, $landing_company, @aml_updated_clients) = @_;

    my $emit;
    try {
        $emit = BOM::Platform::Event::Emitter::emit(
            'aml_client_status_update',
            {
                template_args => {
                    landing_company     => $landing_company,
                    aml_updated_clients => @aml_updated_clients
                }});
        return 1;
    }
    catch {
        $log->errorf('Failed to emit event for emit_aml_status_change_event:  error : %s', $@);
        return undef;
    }
}

1

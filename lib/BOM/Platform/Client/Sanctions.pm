package BOM::Platform::Client::Sanctions;

use Moose;

use Data::Validate::Sanctions;
use BOM::Platform::Config;
use Client::Account;

has client => (
    is       => 'ro',
    isa      => 'Client::Account',
    required => 1,
);
has type => (
    is      => 'ro',
    default => 'R'
);

=head2 skip_email

 Don't send notify email if this is not set.
 Can be used to send aggregated statistics from outside.

=cut

has skip_email => (
    is      => 'ro',
    default => 0,
);

has brand => (
    is       => 'ro',
    isa      => 'Brands',
    required => 1,
);

our $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Platform::Config::sanction_file);

=head2 check

 Check client against sanctioned list. For virtual check is not done. For unauthenticated clients, client is blocked & email is sent.

 Returns none if not matched, and 1 if matched.

=cut

sub check {
    my $self   = shift;
    my $client = $self->client;

    return if $client->is_virtual;

    my $sanctioned = $sanctions->is_sanctioned($client->first_name, $client->last_name);
    $client->add_sanctions_check({
        type   => $self->type,
        result => $sanctioned
    });

    # we don't mark or log fully_authenticated clients
    return unless $sanctioned or $client->client_fully_authenticated;

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);

    # do not add another note & block if client is already disabled
    if (!$client->get_status('disabled')) {
        $client->set_status('disabled', 'system', 'client disabled as marked as UNTERR');
        $client->save;
        $client->add_note('UNTERR', "UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list.");
    }
    send_email({
            from    => $self->brand->emails('support'),
            to      => $self->brand->emails('compliance'),
            subject => $client->loginid . ' marked as UNTERR',
            message => ["UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list."],
        }) unless $self->skip_email;
    return 1;
}

__PACKAGE__->meta->make_immutable;
1;

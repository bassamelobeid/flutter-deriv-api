package BOM::Platform::Client::Sanctions;

use Moose;

use BOM::Platform::Config;
use BOM::Platform::Email qw(send_email);
use Client::Account;
use Data::Validate::Sanctions;

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

 Returns none if not matched, and list id if matched.

=cut

sub check {
    my $self   = shift;
    my $client = $self->client;

    return if $client->is_virtual;

    my $sanctioned_info = $sanctions->get_sanctioned_info($client->first_name, $client->last_name);

    $client->sanctions_check({
        type   => $self->type,
        result => $sanctioned_info->{matched} ? $sanctioned_info->{list} : '',
    });
    $client->save;

    # we don't mark or log fully_authenticated clients
    return if (not $sanctioned_info->{matched} or $client->client_fully_authenticated);

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);

    my $message =
          "UN Sanctions: $client_loginid suspected ($client_name)\n"
        . "Check possible match in UN sanctions list found in [$sanctioned_info->{list}, "
        . Date::Utility->new($sanctions->last_updated($sanctioned_info->{list}))->date . "].";

    # do not send notification if client is already disabled
    if (!$client->get_status('disabled')) {
        send_email({
                from    => $self->brand->emails('compliance'),
                to      => join(',', $self->brand->emails('compliance'), $self->brand->emails('support')),
                subject => $client->loginid . ' possible match in sanctions list',
                message => [$message],
            }) unless $self->skip_email;
    }
    return $sanctioned_info->{list};
}

__PACKAGE__->meta->make_immutable;
1;

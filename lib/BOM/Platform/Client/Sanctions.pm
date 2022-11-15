package BOM::Platform::Client::Sanctions;

use Moose;
use feature qw(state);
use BOM::Config;
use BOM::Config::Redis;
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Data::Validate::Sanctions;

has client => (
    is       => 'ro',
    isa      => 'BOM::User::Client',
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

has recheck_authenticated_clients => (
    is      => 'ro',
    default => 0
);

=head2 sanctions

    return a Data::Validate::Sanctions object

=cut

sub sanctions {
    state $sanctions = Data::Validate::Sanctions->new(
        storage    => 'redis',
        connection => BOM::Config::Redis::redis_replicated_read());
    return $sanctions;
}

=head2 check

 Check client against sanctioned list. For virtual check is not done. For unauthenticated clients, client is blocked & email is sent.

It takes following named args:

=over 4

=item - comments: (optional) additional comments to be appended to email body

=item - triggered_by: (optional) the process in which the sanctions check is triggered, to be appended to email subject

=back

 Returns none if not matched, and list id if matched.

=cut

sub check {
    my ($self, %args) = @_;
    my $client = $self->client;

    return if $client->is_virtual;

    my %query           = map { $_ => $client->$_ } (qw/first_name last_name date_of_birth place_of_birth citizen residence/);
    my $sanctioned_info = sanctions()->get_sanctioned_info(\%query);
    $client->sanctions_check({
        type   => $self->type,
        result => $sanctioned_info->{matched} ? $sanctioned_info->{list} : '',
    });
    $client->save;

    # we don't mark or log fully_authenticated clients
    return if (!$sanctioned_info->{matched} || $client->fully_authenticated && !$self->recheck_authenticated_clients);

    my $client_loginid = $client->loginid;
    my $client_name    = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $matched_fields = join(',', keys $sanctioned_info->{matched_args}->%*);

    my $message =
          "UN Sanctions: $client_loginid suspected (Client's name is $client_name) - similar to $sanctioned_info->{matched_args}->{name}\n"
        . "Check possible match in UN sanctions list found in [$sanctioned_info->{list}, "
        . Date::Utility->new(sanctions()->last_updated($sanctioned_info->{list}))->date . "].\n"
        . "Matched fields: $matched_fields \n"
        . ($sanctioned_info->{comment} ? "Comments: $sanctioned_info->{comment} \n" : '');

    my $subject = $client->loginid . ' possible match in sanctions list';
    $subject .= " - $args{triggered_by}" if $args{triggered_by};

    # do not send notification if client is already disabled
    send_email({
            from    => $self->brand->emails('system'),
            to      => $self->brand->emails('compliance'),
            subject => $subject,
            message => [$message, $args{comments} // ''],
        }) unless ($self->skip_email or $client->status->disabled);

    return $sanctioned_info->{list};
}

__PACKAGE__->meta->make_immutable;
1;

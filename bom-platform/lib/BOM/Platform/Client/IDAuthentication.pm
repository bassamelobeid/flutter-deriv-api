package BOM::Platform::Client::IDAuthentication;

use Moo;
use Syntax::Keyword::Try;
use List::Util qw( first );

use BOM::User::Client;
use BOM::Config;
use XML::LibXML;
use Text::Markdown;
use BOM::Platform::Email   qw(send_email);
use BOM::Platform::Context qw(localize request);
use feature 'state';

has event => (
    is      => 'rw',
    default => 'no_event'
);

has client => (
    is       => 'ro',
    required => 1
);

use constant NEEDED_MATCHES_FOR_ONLINE_AUTH      => 2;
use constant NEEDED_MATCHES_FOR_AGE_VERIFICATION => 1;

=head2 run_validation

Takes in a client event name and runs the appropriate validations for that event

=cut

sub run_validation {
    my ($self, $event) = @_;

    my $client  = $self->client;
    my $loginid = $client->loginid;
    $self->event($event);

    return if $client->is_virtual || $client->fully_authenticated;

    my $landing_company = $client->landing_company;

    my $actions = $landing_company->actions->{$event};

    my %error_info = ();

    state $action_mapping = {
        age_verified     => \&_age_verified,
        fully_auth_check => \&_fully_auth_check,
    };

    for my $action (@$actions) {
        my $mapped_action = $action_mapping->{$action};
        unless ($mapped_action) {
            warn "Invalid requirement";
            next;
        }

        try {
            $self->$mapped_action();
        } catch ($e) {
            $error_info{$action} = $e;
        }
    }

    warn "$loginid $event validation $_ fail: " . $error_info{$_} for keys %error_info;

    return 1;
}

=head2 run_authentication

This is called for validation checks on first time deposits. Deprecated for run_validation().

=cut

sub run_authentication {
    return shift->run_validation('first_deposit');
}

=head2 _age_verified

Checks if client is age verified, if not, set cashier lock on client

=cut

sub _age_verified {
    my $self   = shift;
    my $client = $self->client;

    if (!$client->status->age_verification) {
        $client->status->setnx('unwelcome', 'system', 'Age verification is needed after first deposit.');
    }

    return undef;
}

=head2 _fully_auth_check

Checks if client is fully authenticated and remove unwelcome, if not, set client as unwelcome

=cut

sub _fully_auth_check {
    my $self   = shift;
    my $client = $self->client;

    if ($client->fully_authenticated) {
        $client->status->clear_unwelcome if $client->status->unwelcome;
    } else {
        $client->status->upsert("unwelcome", "system", "Client was not fully authenticated before making first deposit")
            unless $client->landing_company->first_deposit_auth_check_required;
    }
    return undef;
}

1;

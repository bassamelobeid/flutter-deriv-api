package BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use Syntax::Keyword::Try;

=head1 DESCRIPTION

This package entry point for all third party payment processors
when called, uses a new instance of the related payment processor/provider.

=cut

=head2 new

Resolves the requested package and creates a new instance.

Receives a hashref containing arguments to be passed to the resolved package
including the following named parameter (won't be passed to the resolved package):

=over 4

=item * C<processor_name> - third party processor name eg Coinspaid, etc.

=back

Returns a new instance of the resolved package if found, otherwise C<undef>.

=cut

sub new {    ## no critic
    my ($self, %args) = @_;

    return undef unless $args{processor_name};

    my $processor_package = join '::', $self, $args{processor_name};
    # Get file path from package name e.g
    # `BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid` => BOMPlatform/CryptoWebhook/Webhook/PaymentProcessor/Coinspaid`
    (my $file = $processor_package) =~ s|::|/|g;

    try {
        require $file . '.pm';
        $processor_package->import();
        # Avoid passing these to the package
        delete $args{processor_name};
        return $processor_package->new(\%args);
    } catch ($e) {
        $log->warnf('Error finding/loading processor package. Error: %s', $e);
        return undef;
    }
}

1;

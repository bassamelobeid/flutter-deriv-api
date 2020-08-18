
package BOM::Event::Utility;

use strict;
use warnings;
use DataDog::DogStatsd::Helper qw(stats_inc);
use Exporter qw(import);
our @EXPORT_OK = qw(try_logged exception_logged);
use Syntax::Keyword::Try;
use constant GENERIC_DD_STATS_KEY => 'bom.events.exception';

=head2 exception_logged

A function to log exceptions in bom-events to the Datadog metrics.
B<Note>: Keep synced with bom-rpc Utility.pm

Example usage:

Use inside a C<catch> block like this:

 try {
    .....
 }
 catch {
    .... 
    exception_logged();
 }

and it will automatically increment the exception count in Datadog if any exception occurs.

=back

Returns undef

=cut

sub exception_logged {
    my $idx = 0;
    ++$idx while (caller $idx)[3] =~ /\b(?:eval|ANON|__ANON__|exception_logged)\b/;

    my $caller = (caller $idx)[3];
    _add_metric_on_exception($caller);
    return undef;
}

=head2 _add_metric_on_exception

Increment the exception count in the Datadog
Note : Keep synced with bom-rpc Utility.pm

Example usage:

_add_metric_on_exception(...)

Takes the following arguments as named parameters

=over 4

=item * C<caller> - A string which should generated by caller() function

=back

Returns undef

=cut

sub _add_metric_on_exception {
    my ($caller) = @_;
    my @tags = _convert_caller_to_array_of_tags($caller);

    stats_inc(GENERIC_DD_STATS_KEY, {tags => \@tags});
    return undef;
}

=head2 _convert_caller_to_array_of_tags

Converts Caller into array of tags. Which contains package and method name.
Note : Keep synced with bom-rpc Utility.pm

Example usage:

_convert_caller_to_array_of_tags(...)

Takes the following arguments as named parameters

=over 4

=item * C<caller> - A string which should generated by caller() function

=back

Returns array of tags which contains package and method name.

=cut

sub _convert_caller_to_array_of_tags {
    my ($caller)      = @_;
    my @dd_tags       = ();
    my @array_subname = split("::", $caller);

    my $method  = pop @array_subname;
    my $package = join("::", @array_subname);

    push @dd_tags, lc('package:' . $package) if ($package);
    push @dd_tags, lc('method:' . $method)   if ($method);

    return @dd_tags;
}

1;

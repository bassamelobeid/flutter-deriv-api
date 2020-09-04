package BOM::Event::Actions::Email;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);

use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(process_send_email);

=head2 send_email_generic

Uses C<BOM::Platform::Email::process_send_email> as of now to send an email
based on the given args.

=over 4

=item * C<args> - The arguments needed to pass to C<process_send_email> - Arguments are described there as well

=back

=head3 Main arguments:

=over 4

=item * C<from> - Email address of the sender

=item * C<to> - The recipient email address

=item * C<subject> - Subject of the email

=back

=head3 Optional arguments:

=over 4

=item * C<message> - An arrayref of messages that would be joined to send, will be ignored if C<template_name> is present

=item * C<skip_text2html> - If 0 converts plain text to HTML, only applicable if C<message> is passed

=item * C<layout> - (optional) The layout to be used for the email, defaults to C<layouts/default.html.tt>

=item * C<template_name> - Name of the template located under C<Brands/share/[brand]/templates>

=item * C<template_args> - The variables to be passed to the template while processing

=item * C<use_email_template> - If 1, uses the layout and given template

=item * C<email_content_is_html> - If 1, treats the email content as HTML, otherwise as text

=back

Returns 1 if email has been sent, otherwise 0

=cut

sub send_email_generic {
    my $args = shift;

    my $status_code = process_send_email($args);

    $log->errorf(
        'Failed to send the email with subject: %s - template_name: %s - request_brand_name: %s',
        $args->{subject},
        $args->{template_name},
        request()->brand->name
    ) unless $status_code;

    return $status_code;
}

1;

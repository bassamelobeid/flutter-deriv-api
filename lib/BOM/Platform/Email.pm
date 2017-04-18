package BOM::Platform::Email;

use strict;
use warnings;

use URL::Encode;
use Email::Stuffer;
use Try::Tiny;
use Encode;

use Brands;

use BOM::Platform::Config;
use BOM::Platform::Context qw(request localize);

use parent 'Exporter';
our @EXPORT_OK = qw(send_email);

=head2 send_email

Send the email. Return 1 if success, otherwise 0

=cut

sub send_email {
    my $args_ref           = shift;
    my $fromemail          = $args_ref->{'from'} // '';
    my $email              = $args_ref->{'to'} // '';
    my $subject            = $args_ref->{'subject'} // '';
    my @message            = @{ $args_ref->{'message'} // [] };
    my $use_email_template = $args_ref->{'use_email_template'};
    my $attachment         = $args_ref->{'attachment'};
    my $skip_text2html     = $args_ref->{'skip_text2html'};
    my $template_loginid   = $args_ref->{template_loginid};

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    unless ( $email && $fromemail && $subject ) {
        warn(
"from, to, or subject missed - [from: $fromemail, to: $email, subject: $subject]"
        );
        return 0;
    }

# replace all whitespace - including vertical such as CR/LF - with a single space
    $subject =~ s/\s+/ /g;

    return 1 if $ENV{SKIP_EMAIL};

    my @toemails = split( /\s*\,\s*/, $email );
    foreach my $toemail (@toemails) {
        if (    $toemail
            and $toemail !~
            /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$/ )
        {
            warn("erroneous email address $toemail");
            return 0;
        }
    }

    my $brand = Brands->new( name => request()->brand );
    if ( $fromemail eq $brand->emails('support') ) {
        $fromemail = "\"" . $brand->website_name . "\" <$fromemail>";
    }

    my $message = join( "\n", @message );
    my $mail_message = $message;
    if ($use_email_template) {
        my $vars = {

# Allows inline HTML, default is off - be very, very careful when setting this #
            email_content_is_html => $args_ref->{'email_content_is_html'},
            skip_text2html        => $skip_text2html,
            content               => $message,
        };
        $vars->{text_email_template_loginid} =
          localize( 'Your Login ID: [_1]', $template_loginid )
          if $template_loginid;
        if ( $language eq 'JA' ) {
            $vars->{japan_footer_text} =
              localize('{JAPAN ONLY}footer text of email template for Japan');
        }
        BOM::Platform::Context::template->process( 'common_email.html.tt',
            $vars, \$mail_message )
          || die BOM::Platform::Context::template->error();
    }

    my $email_stuffer =
      Email::Stuffer->from($fromemail)->to($email)->subject($subject)
      ->text_body($mail_message);
    if ($attachment) {
        $email_stuffer->attach_file($attachment);
    }

    try {
        $email_stuffer->send;
        1;
    }
    catch {
        warn( "Error sending mail [$subject]: ", $_ )
          unless $ENV{BOM_SUPPRESS_WARNINGS};
        0;
    } or return 0;

    return 1;
}

1;

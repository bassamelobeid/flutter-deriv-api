package BOM::Platform::Email;

use strict;
use warnings;

use URL::Encode;
use Email::Stuffer;
use HTML::FromText;
use Try::Tiny;
use Encode;

use Brands;

use BOM::System::Config;
use BOM::Platform::Context qw(request localize);

use parent 'Exporter';
our @EXPORT_OK = qw(send_email);

# Note that this function has two ways to indicate errors: it may raise an exception, or return false.
# Ideally we should pick one for consistency.
sub send_email {
    my $args_ref           = shift;
    my $fromemail          = $args_ref->{'from'};
    my $email              = $args_ref->{'to'};
    my $subject            = $args_ref->{'subject'};
    my @message            = @{$args_ref->{'message'}};
    my $use_email_template = $args_ref->{'use_email_template'};
    my $attachment         = $args_ref->{'attachment'};
    # This is no longer used, since the MIME type on the attachment is autodetected
    # ($ctype is slightly confusing as a variable name - it applied only to the
    # attachment, not any of the other MIME parts...)
    my $ctype              = $args_ref->{'att_type'} // 'text/plain';
    my $skip_text2html     = $args_ref->{'skip_text2html'};
    my $template_loginid   = $args_ref->{template_loginid};

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    die 'No email provided' unless $email;

    if (not $fromemail) {
        # FIXME so this is most likely going to leave undef warnings
        warn("fromemail missing - [$fromemail, $email, $subject]");
        return 0;
    }
    # FIXME this is redundant, we already died if this was missing
    if (not $email) {
        warn("email missing - [$fromemail, $email, $subject]");
        return 0;
    }
    if (not $subject) {
        # FIXME also likely to leave undef warnings
        warn("subject missing - [$fromemail, $email, $subject]");
        return 0;
    }

    # replace all whitespace - including vertical such as CR/LF - with a single space
    $subject =~ s/\s+/ /g;

    return 1 if $ENV{SKIP_EMAIL};

    my @toemails = split(/\s*\,\s*/, $email);
    foreach my $toemail (@toemails) {
        if ($toemail and $toemail !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$/) {
            warn("erroneous email address $toemail");
            return 0;
        }
    }

    my $brand = Brands->new(name => request()->brand);
    if ($fromemail eq $brand->emails('support')) {
        $fromemail = "\"" . $brand->website_name . "\" <$fromemail>";
    }

    my $message = join("\n", @message);

    # To avoid Mail::Sender return error "500 5.5.2 Error: bad syntax"
    local $\ = "";

    if ($attachment) {
        try {
            Email::Stuffer
                ->from($fromemail)
                ->to($email)
                ->subject($subject)
                ->text_body($message)
                ->attach_file($attachment)
                ->send;
            1
        }
        catch {
            warn("Error sending mail: ", $_) unless $ENV{BOM_SUPPRESS_WARNINGS};
            0;
        } or return 0;
    } else {
        unless ($skip_text2html) {
            $message = text2html(
                $message,
                urls      => 1,
                email     => 1,
                lines     => 1,
                metachars => 0,
            );
        }

        my $mail_message;
        if ($use_email_template) {
            my $vars = {content => $message};
            $vars->{text_email_template_loginid} = localize('Your Login ID: [_1]', $template_loginid) if $template_loginid;
            if ($language eq 'JA') {
                $vars->{japan_footer_text} = localize('{JAPAN ONLY}footer text of email template for Japan');
            }
            BOM::Platform::Context::template->process('common_email.html.tt', $vars, \$mail_message)
                || die BOM::Platform::Context::template->error();
        } else {
            $mail_message = $message;
        }

        try {
            Email::Stuffer
                ->from($fromemail)
                ->to($email)
                ->subject($subject)
                ->html_body($message)
                ->send;
            1
        }
        catch {
            warn("Error sending mail [$subject]: ", $_) unless $ENV{BOM_SUPPRESS_WARNINGS};
            0;
        } or return 0;
    }

    return 1;
}

1;

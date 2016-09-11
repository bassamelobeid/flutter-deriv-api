package BOM::Platform::Email;

use strict;
use warnings;

use Sys::Hostname qw( );
use URL::Encode;
use Email::Stuffer;
use HTML::FromText;
use Try::Tiny;
use Encode;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::System::Config;

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
    my $ctype              = $args_ref->{'att_type'} // 'text/plain';
    my $skip_text2html     = $args_ref->{'skip_text2html'};
    my $template_loginid   = $args_ref->{template_loginid};

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    die 'No email provided' unless $email;

    if (not $fromemail) {
        warn("fromemail missing - [$fromemail, $email, $subject]");
        return 0;
    }
    if (not $email) {
        warn("email missing - [$fromemail, $email, $subject]");
        return 0;
    }
    if (not $subject) {
        warn("subject missing - [$fromemail, $email, $subject]");
        return 0;
    }

    # replace all whitespace - including vertical such as CR/LF - with a single space
    $subject =~ s/\s+/ /g;
    my $prefix = BOM::Platform::Runtime->instance->app_config->system->alerts->email_subject_prefix;

    my @name = split(/\./, Sys::Hostname::hostname);
    my $server = $name[0];

    $prefix =~ s/_HOST_/$server/g;
    $prefix =~ s/\[//;
    $prefix =~ s/\]//;
    $subject = $prefix . $subject;

    # DON'T send email on devbox except to RMG emails
    return 1
        if (not BOM::System::Config::on_production()
        and $email !~ /(?:binary|regentmarkets|betonmarkets)\.com$/);

    my @toemails = split(/\s*\,\s*/, $email);
    foreach my $toemail (@toemails) {
        if ($toemail and $toemail !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$/) {
            warn("erroneous email address $toemail");
            return 0;
        }
    }

    if ($fromemail eq BOM::Platform::Runtime->instance->app_config->cs->email) {
        $fromemail = "\"Binary.com\" <$fromemail>";
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
            my $vars = {
                email_template_loginid => $template_loginid,
                content                => $message,
            };
            if ($language eq 'JA') {
                $vars->{email_template_japan} = $language;
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

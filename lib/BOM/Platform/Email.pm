package BOM::Platform::Email;

use 5.010;
use strict;
use warnings;

use Sys::Hostname qw( );
use URL::Encode;
use Mail::Sender;
use HTML::FromText;
use Try::Tiny;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);

use base 'Exporter';
our @EXPORT_OK = qw(send_email);

$Mail::Sender::NO_X_MAILER = 1;    # avoid hostname/IP leak

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

    die 'No email provided' unless $email;

    if (not $fromemail) {
        warn("fromemail missing - [$fromemail, $email, $subject]");
        return;
    }
    if (not $email) {
        warn("email missing - [$fromemail, $email, $subject]");
        return;
    }
    if (not $subject) {
        warn("subject missing - [$fromemail, $email, $subject]");
        return;
    }

    # strip carriage returns in subject
    $subject =~ s/[\r\n\f\t]/ /g;
    my $prefix = BOM::Platform::Runtime->instance->app_config->system->alerts->email_subject_prefix;

    my @name = split(/\./, Sys::Hostname::hostname);
    my $server = $name[0];

    $prefix =~ s/_HOST_/$server/g;
    $prefix =~ s/\[//;
    $prefix =~ s/\]//;
    $subject = $prefix . $subject;

    # DON'T send email on devbox except to RMG emails
    return 1
        if (not BOM::Platform::Runtime->instance->app_config->system->send_email_to_clients
        and $email !~ /(?:binary|regentmarkets|betonmarkets)\.com$/);

    my @toemails = split(/\s*\,\s*/, $email);
    foreach my $toemail (@toemails) {
        if ($toemail and $toemail !~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$/) {
            warn("erroneous email address $toemail");
            return;
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
            Mail::Sender->new({
                    smtp      => 'localhost',
                    from      => $fromemail,
                    to        => $email,
                    charset   => 'UTF-8',
                    b_charset => 'UTF-8',
                    on_errors => 'die',
                }
                )->MailFile({
                    subject => $subject,
                    msg     => $message,
                    ctype   => $ctype,
                    file    => $attachment,
                });
        }
        catch {
            warn("Error sending mail: ", $Mail::Sender::Error // $_) unless $ENV{BOM_SUPPRESS_WARNINGS};
            0;
        } or return;
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
            BOM::Platform::Context::template->process('common_email.html.tt', $vars, \$mail_message)
                || die BOM::Platform::Context::template->error();
        } else {
            $mail_message = $message;
        }

        try {
            Mail::Sender->new({
                    smtp      => 'localhost',
                    from      => $fromemail,
                    to        => $email,
                    ctype     => 'text/html',
                    charset   => 'UTF-8',
                    encoding  => "quoted-printable",
                    on_errors => 'die',
                }
                )->Open({
                    subject => $subject,
                })->SendEnc($mail_message)->Close();
        }
        catch {
            warn("Error sending mail [$subject]: ", $Mail::Sender::Error // $_) unless $ENV{BOM_SUPPRESS_WARNINGS};
            0;
        } or return;
    }

    return 1;
}

1;

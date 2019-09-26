package BOM::Platform::Email;

use strict;
use warnings;

use Email::Address::UseXS;
use URL::Encode;
use Email::Stuffer;
use Email::Valid;
use Encode;

use BOM::Config;
use BOM::Platform::Context qw(request localize);
use BOM::Database::Model::OAuth;

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
    my $template_name      = $args_ref->{'template_name'} // '';
    my $template_args      = $args_ref->{'template_args'} // {};
    my @message            = @{$args_ref->{'message'} // []};
    my $use_email_template = $args_ref->{'use_email_template'};
    my $layout             = $args_ref->{'layout'} // 'default';
    my $attachment         = $args_ref->{'attachment'} // [];
    $attachment = ref($attachment) eq 'ARRAY' ? $attachment : [$attachment];
    my $skip_text2html   = $args_ref->{'skip_text2html'};
    my $template_loginid = $args_ref->{template_loginid};

    my $request = request();

    unless ($email && $fromemail && $subject) {
        warn("from, to, or subject missed - [from: $fromemail, to: $email, subject: $subject]");
        return 0;
    }

# replace all whitespace - including vertical such as CR/LF - with a single space
    $subject =~ s/\s+/ /g;

    return 1 if $ENV{SKIP_EMAIL};

    my @toemails = split(/\s*\,\s*/, $email);
    foreach my $toemail (@toemails) {
        if ($toemail and not Email::Valid->address($toemail)) {
            warn("erroneous email address $toemail");
            return 0;
        }
    }

    my $brand = request()->brand;
    if ($fromemail eq $brand->emails('support')) {
        $fromemail = "\"" . $brand->website_name . "\" <$fromemail>";
    }

    my $message = join("\n", @message);
    my $mail_message = $message;
    if ($use_email_template) {
        $template_name .= '.html.tt' if $template_name and $template_name !~ /\.html\.tt$/;
        $mail_message = '';
        my $vars = {
            # Allows inline HTML, default is off - be very, very careful when setting this #
            email_content_is_html => $args_ref->{'email_content_is_html'},
            skip_text2html        => $skip_text2html,
            content               => $message,
            content_template      => $template_name,
            l                     => \&localize,
            $template_args->%*,
        };
        $vars->{text_email_template_loginid} = localize('Your Login ID: [_1]', $template_loginid)
            if $template_loginid;

        $vars->{website_url} = $brand->default_url;
        my $app_id = $request->source || '';
        if ($brand->is_app_whitelisted($app_id)) {
            my $app = BOM::Database::Model::OAuth->new->get_app_by_id($app_id);
            $vars->{website_url} = $app->{redirect_uri} if $app;
        }

        BOM::Platform::Context::template()->process("layouts/$layout.html.tt", $vars, \$mail_message)
            || die BOM::Platform::Context::template()->error();
    }

    my $email_stuffer = Email::Stuffer->from($fromemail)->to($email)->subject($subject);

    # Add email host for docker to work
    if ($ENV{EMAIL_HOST}) {
        require Email::Sender::Transport::SMTP;
        $email_stuffer->transport(Email::Sender::Transport::SMTP->new({host => $ENV{EMAIL_HOST}}));
    }

    if ($args_ref->{'email_content_is_html'} || $use_email_template) {
        $email_stuffer->html_body($mail_message);
    } else {
        $email_stuffer->text_body($mail_message);
    }

    for my $attach_file (@$attachment) {
        $email_stuffer->attach_file($attach_file);
    }

    return try {
        $email_stuffer->send_or_die;
        return 1;
    }
    catch {
        warn("Error sending mail [$subject]: ", $_)
            unless $ENV{BOM_SUPPRESS_WARNINGS};
        return 0;
    };
}

1;

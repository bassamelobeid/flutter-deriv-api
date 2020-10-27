###############################################################################################
#
#                            subs_presentation_backoffice
#
# This module contains the presentation routines of the BACKOFFICE
#
###############################################################################################
## no critic (RequireExplicitPackage)
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use Mojo::URL;
use BOM::JavascriptConfig;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth0;
use BOM::Backoffice::CGI::SettingWebsiteStatus;

our ($vk_BarIsDoneOnce, $vk_didBOtopPRES,);

# "Header" of the backoffice pages
sub BrokerPresentation {
    my ($title, $title_description, $is_menu_hidden, $output_type) = @_;

    if ($output_type =~ /csv/ or request()->param('printable')) {
        return;
    }

    print '<html>';
    print '<head>';
    print "<title>$title-$ENV{REMOTE_ADDR}</title>";
    print '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">';

    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/' . $_) . '"/>'
        for ('style.css', 'sell_popup.css', 'external/grid.css', 'external/jquery-ui.custom.css');

    foreach my $js_file (BOM::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }

    print '</head>';
    print '<body class="BlueTopBack">';

    if (not $is_menu_hidden) {
        vk_BOtopPRES();
    }

    if ($title) {
        print "
            <div id='main_title'>
                $title $title_description
                <a class='scroll-top' title='Scroll to top' href='javascript:;' onclick='smoothScroll()'></a>
            </div>";
    }

    return;
}

=head2 Bar

Prints opening tags of a sub-section.

B<Note:> For historical reasons, this code does not close some of the tags it opens,
it just implicitly sets a value for C<vk_BarIsDoneOnce> to close the tags in the
next call by C<BarEnd()> sub. Hence, be careful with the contents you render
afterwards, as an extra closing tag might break the UI.

Changing this behaviour would need a huge refactoring everywhere. That's why we're
keeping it as is, for now. Might need the change if we don't plan for a modern
BackOffice in the near future.

If you are re-writing this code, make sure the opening/closing tags remain
the same as they are now.

Takes the following arguments:

=over 4

=item * C<title> - The panel's title, would change to uppercase for display

=item * C<options> - (optional) A hashref containing following parameters to change the display:

=over 4

=item * C<container_class> - (optional) The CSS class name of the section's container

=item * C<title_class> - (optional) The CSS class name of the section's title

=item * C<is_content_centered> - (optional) A boolean value, set to 1 for aligning contents to center

=back

=back

=cut

sub Bar {
    my ($title, $options) = @_;

    $title = uc($title // '');
    my $container_class = $options->{container_class} // 'BlackCandy';
    my $title_class     = $options->{title_class}     // 'Blacklabel';
    my $content_align = $options->{is_content_centered} ? 'center' : '';

    BarEnd();    #see sub below

    print qq~
        <div class="container $container_class">
            <div class="$title_class whitelabel">$title</div>
            <div class="contents $content_align">~;

    $vk_BarIsDoneOnce = 'yes';
    return;
}

sub BarEnd {
    if (not $vk_BarIsDoneOnce) { return; }
    print '</div></div>';
    return;
}

sub ServerWarningBar {
    my $location = shift // '';

    my $state_key  = BOM::Backoffice::CGI::SettingWebsiteStatus::get_redis_keys()->{state};
    my $reasons    = BOM::Backoffice::CGI::SettingWebsiteStatus::get_messages();
    my $redis      = BOM::Config::Redis->redis_ws();
    my $ip_message = "Your IP: $ENV{'REMOTE_ADDR'}";
    my $state      = eval { decode_json_utf8($redis->get($state_key) // '{}') };
    $state->{site_status} //= 'up';
    $state->{message}     //= '';

    if (BOM::Config::on_qa()) {
        my $url = request()->url_for('backoffice/login.cgi?backprice=');
        my ($c, $h) = BOM::Backoffice::Cookie::get_cookie('backprice') ? ('YES', $url . '0') : ('NO', $url . '1');

        $ip_message .= ", backprice config: <a href='$h'>$c</a>";
    }

    my $status_message = sprintf('Site status: %s', uc $state->{site_status});
    $status_message .= sprintf(', %s', $reasons->{$state->{message}}) if defined $reasons->{$state->{message}};

    my $scroll_link =
        $location eq 'bottom'
        ? "<a class='scroll-top' title='Scroll to top' href='javascript:;' style='margin-left: 25px;' onclick='smoothScroll()'></a>"
        : '';

    print qq~
        <div class="info-bar">
            <div>$ip_message</div>
            <div>
                $status_message
                $scroll_link
            </div>
        </div>~;

    return;
}

#### THE FOLLOWING (vk) SUBS ARE THE INTERFACE DESIGN OF B/O

sub vk_BOtopPRES    #this sub executed in BrokerPresentation
{
    my $broker = request()->broker_code;

    my $rand     = '?' . rand(9999);                                                     # to avoid caching on these fast navigation links
    my $vk_BOurl = request()->url_for("backoffice/f_broker_login.cgi", {_r => $rand});

    print qq~
 <table border="0" width="100%" cellspacing="0" cellpadding="0">
  <tr>
   <td bgcolor="#2A3052"><a href="$vk_BOurl" title="Back Office Home Page">
   <img border="0" src="~
        . request()->url_for('images/bo_sign.jpg', undef, undef, {internal_static => 1}) . qq~" width="347" height="68" alt="Back Office Home Page">
   </a></td>
   <td width="100%" bgcolor="#2A3052" align="right"><img border="0" src="~
        . request()->url_for('images/bo_logo.jpg', undef, undef, {internal_static => 1}) . qq~" width="489" height="68"></td>
  </tr>
  <tr><td colspan="2" bgcolor="#E88024" style="height:4px"></td></tr>
 </table>~;

    ServerWarningBar();

    print qq~
    <div id="top_bar" class="blue-bar"></div>
	<table border="0" width="100%" cellspacing="0" cellpadding="0">
	<tr>
	<td valign="top" height="100%" class="main-menu-back">
		<table border="0" cellpadding="0" cellspacing="0" class="main-menu">
            <tbody>
                <tr>
                    <td>
                        <img src="~ . request()->url_for('images/xpicon1.gif', undef, undef, {internal_static => 1}) . qq~" height="32" width="31">
                    </td>
                    <td valign="bottom">
                        <img src="~ . request()->url_for('images/xptitle.gif', undef, undef, {internal_static => 1}) . qq~" height="25" width="110">
                    </td>
                    <td valign="bottom">
                        <img src="~ . request()->url_for('images/xpexpand1.gif', undef, undef, {internal_static => 1}) . qq~" height="25" width="25">
                    </td>
                </tr>~;

    my @menu_items = (
        {text => 'Main Sections'},
        {
            link => 'f_broker_login',
            text => 'Login Page'
        },
        {
            link => 'f_bo_enquiry',
            text => 'Transaction Reports'
        },
        {
            link => 'f_accountingreports',
            text => 'Accounting Reports'
        },
        {
            link => 'f_manager',
            text => 'Deposits & Withdrawals'
        },
        {
            link => 'f_clientloginid',
            text => 'Client Management'
        },
        {text => 'Misc. Tools'},
        {
            link => 'f_investigative',
            text => 'Investigative Tools'
        },
        {
            link => 'f_client_anonymization',
            text => 'Client Anonymization'
        },
        {
            link => 'crypto_admin',
            text => 'Crypto Tools'
        },
        {text => 'Log Out'},
        {
            link    => 'login',
            text    => 'Log Out',
            options => {whattodo => 'logout'}
        },
    );
    my $current_script = request()->http_handler->script_name;

    for my $item (@menu_items) {
        if ($item->{link}) {
            my $current_class = $current_script =~ /^\/$item->{link}\.cgi$/ ? 'class="current"' : '';
            my $url           = request()->url_for(
                "backoffice/$item->{link}.cgi",
                {
                    _r     => $rand,
                    broker => $broker,
                    ($item->{options} // {})->%*,
                });
            print qq~
            <tr>
                <td colspan="3">
                    <a href="$url" $current_class>$item->{text}</a>
                </td>
            </tr>~;
        } else {
            print qq~
            <tr>
                <td colspan="3" class="menu-section-title">$item->{text}</td>
            </tr>~;
        }
    }

    print qq~
            </tbody>
        </table>
    </td>
    <td width="100%" valign="top" align="center">
        <div style="margin: 10px;">~;

    $vk_didBOtopPRES = 'yes';

    return;
}

sub vk_BObottomPRES {
    if (not $vk_didBOtopPRES) { return; }

    print '</div></td></tr></table>';    # Eventually can be more different stuff here

    ServerWarningBar('bottom');

    print '</body></html>';

    return;
}

# CGI::Compile will wrap the function 'exit' into a `die "EXIT\n" $errcode`
# So please don't use it in `try` block. Otherwise it will be caught.
# If you still want to do, please throw it again in the catch block.
# please refer to perldoc of CGI::Compile and Try::Tiny::Except

sub code_exit_BO {
    my ($message, $title, $is_success) = @_;
    if ($message) {
        Bar(
            $title,
            {
                container_class => $is_success ? 'GreenDarkCandy' : 'RedCandy',
                title_class     => $is_success ? 'GreenLabel'     : 'RedLabel',
                is_content_centered => 1,
            });
        print $message;
    }
    if ($vk_BarIsDoneOnce) { BarEnd(); }             #backoffice closing bar output (must be before vk_BObottomPRES)
    if ($vk_didBOtopPRES)  { vk_BObottomPRES(); }    #backoffice closing presentation
    no strict "refs";                                ## no critic (ProhibitNoStrict, ProhibitProlongedStrictureOverride)
    undef ${"main::vk_BarIsDoneOnce"};
    undef ${"main::vk_didBOtopPRES"};
    BOM::Backoffice::Request::request_completed();
    exit 0;
}

1;

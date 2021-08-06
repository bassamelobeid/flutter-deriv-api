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
    print '<meta name="viewport" content="width=device-width, initial-scale=1">';
    print '<link rel="preconnect" href="https://fonts.gstatic.com">';
    print '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;700&display=swap" rel="stylesheet">';

    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/' . $_) . '"/>'
        for ('style_new.css?v=2021-06-23', 'sell_popup.css', 'external/grid.css?v=2021-03-31', 'external/jquery-ui.custom.css?v=2021-05-06');

    foreach my $js_file (BOM::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }

    print '</head>';
    print '<body>';

    if (not $is_menu_hidden) {
        vk_BOtopPRES();
    }

    print '<main>';

    if ($title) {
        print "
            <p id='main_title'>
                $title $title_description
                <a class='scroll-top' title='Scroll to top' href='javascript:;' onclick='smoothScroll()'></a>
            </p>";
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

=item * C<collapsed> - (optional) A boolean value, set to 1 to collapse contents

=item * C<nav_link> - (optional) A string value, set the top_bar navigation link's name and href

=item * C<content_class> - (optional) The CSS class name of the section's content

=back

=back

=cut

sub Bar {
    my ($title, $options) = @_;

    $title = uc($title // '');
    my $container_class = $options->{container_class} // 'card';
    my $title_class     = $options->{title_class}     // 'card__label toggle';
    my $content_align   = $options->{is_content_centered} ? 'center'                                 : '';
    my $collapsed       = $options->{collapsed}           ? 'collapsed'                              : '';
    my $nav_link        = $options->{nav_link}            ? qq~data-nav-link="$options->{nav_link}"~ : '';
    my $content_class   = $options->{content_class} // '';

    BarEnd();    #see sub below

    print qq~
        <div class="$container_class">
            <div class="$title_class $collapsed" $nav_link>$title</div>
            <div class="card__content $content_class $content_align">~;

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
    my $ip_message = "Your IP: <strong>$ENV{'REMOTE_ADDR'}</strong>";
    my $state      = eval { decode_json_utf8($redis->get($state_key) // '{}') };
    $state->{site_status} //= 'up';
    $state->{message}     //= '';

    if (BOM::Config::on_qa()) {
        my $url = request()->url_for('backoffice/login.cgi?backprice=');
        my ($c, $h) = BOM::Backoffice::Cookie::get_cookie('backprice') ? ('YES', $url . '0') : ('NO', $url . '1');

        $ip_message .= ", backprice config: <a href='$h' class='link'><strong>$c</strong></a>";
    }

    my $status_message =
        $state->{site_status} eq 'up'
        ? sprintf('Site status: <strong class="success">%s</strong>', uc $state->{site_status})
        : sprintf('Site status: <strong class="error">%s</strong>',   uc $state->{site_status});
    $status_message .= sprintf(', <strong>%s</strong>', $reasons->{$state->{message}}) if defined $reasons->{$state->{message}};

    my $scroll_link =
        $location eq 'bottom'
        ? "<a class='scroll-top' title='Scroll to top' href='javascript:;' onclick='smoothScroll()'></a>"
        : '';

    if ($location eq 'bottom') {
        print qq~</main>~;
        print qq~</div>~;    # closing tag of div.layout_main
    }

    print qq~
        <div class="statusbar">
            <span>$ip_message</span>
            <span>$status_message$scroll_link</span>
        </div>~;

    return;
}

#### THE FOLLOWING (vk) SUBS ARE THE INTERFACE DESIGN OF B/O

sub vk_BOtopPRES    # this sub executed in BrokerPresentation
{
    my $broker = request()->broker_code;

    my $rand     = '?' . rand(9999);                                                     # to avoid caching on these fast navigation links
    my $vk_BOurl = request()->url_for("backoffice/f_broker_login.cgi", {_r => $rand});

    print qq~
    <header>
        <a href="~ . $vk_BOurl . qq~" title="Back Office Home Page">
            <img src="~
        . request()->url_for('images/bo_deriv_logo.svg', undef, undef, {internal_static => 1})
        . qq~" width="347" height="68" alt="Back Office Home Page" />
        </a>
        <div id="settings">
            <span id="gmt_clock" class="gmt_clock" tooltip></span>
            <div class="theme-switch__container">
                <input type="checkbox" id="theme_switcher" name="theme-switch" class="theme-switch__input" />
                <label for="theme_switcher" class="theme-switch__label">
                    <span class="sun_icon">&#9788;</span>
                    <span class="toggler"></span>
                    <span class="moon_icon">&#9790;</span>
                </label>
            </div>
        </div>
        <img src="~
        . request()->url_for('images/bo_binary_brand.svg', undef, undef, {internal_static => 1}) . qq~" />
    </header>
    ~;

    print qq~
    <script>
        /* Render blocking script - sets Theme color before rendering rest of the page to prevent from colors 'flickering' on load */
        const theme = localStorage.getItem('theme');
        if (theme) {
            document.documentElement.setAttribute('data-theme', theme);
            if (theme === 'dark') {
                document.getElementById('theme_switcher').checked = true;
            }
        }
    </script>
    ~;

    ServerWarningBar();

    my @menu_items = ({
            text => 'Main Sections',
            list => [{
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
                }]
        },
        {
            text => 'Misc. Tools',
            list => [{
                    link => 'f_investigative',
                    text => 'Investigative Tools'
                },
                {
                    link => 'f_client_anonymization',
                    text => 'Client Anonymization'
                },
                {
                    link => 'f_client_bulk_authentication',
                    text => 'Bulk Authentication'
                },
                {
                    link => 'crypto_admin',
                    text => 'Crypto Tools'
                },
            ]
        },
        {
            text => 'Log Out',
            list => [{
                    link    => 'login',
                    text    => 'Log Out',
                    options => {whattodo => 'logout'}
                },
            ]

        },
    );
    my $current_script = request()->http_handler->script_name;

    print qq~
    <div class="layout_main">
    <div id="top_bar" class="link-group center"></div>
    <nav>
        <ul class="sidebar">
    ~;
    for my $item (@menu_items) {
        print qq~
            <li>
                <a>$item->{text}</a>
                <ul>
            ~;

        map {
            my $current_class = $current_script =~ /^\/$_->{link}\.cgi$/ ? 'class="current"' : '';
            my $url           = request()->url_for(
                "backoffice/$_->{link}.cgi",
                {
                    _r     => $rand,
                    broker => $broker,
                    ($_->{options} // {})->%*,
                });
            print qq~
                <li>
                    <a href="$url" $current_class>$_->{text}</a>
                </li>~;
        } @{$item->{list}};

        print qq~
                </ul>
            </li>
        ~;
    }
    print qq~
        </ul>
    </nav>
    ~;

    $vk_didBOtopPRES = 'yes';

    return;
}

sub vk_BObottomPRES {
    if (not $vk_didBOtopPRES) { return; }

    print '</div></td></tr></table>';    # Eventually can be more different stuff here

    ServerWarningBar('bottom');

    print '<footer></footer></body></html>';

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
                container_class     => $is_success ? 'card'        : 'card',
                title_class         => $is_success ? 'card__label' : 'card__label',
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

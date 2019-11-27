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

our ($vk_BarIsDoneOnce, $vk_didBOtopPRES,);

# "Header" of the backoffice pages
sub BrokerPresentation {
    my ($Title, $title_description, $noDisplayOfTopMenu, $outputtype) = @_;

    if ($outputtype =~ /csv/ or request()->param('printable')) {
        return;
    }

    print '<html>';
    print '<head>';
    print "<title>$Title-$ENV{REMOTE_ADDR}</title>";
    print '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">';
    print '<link rel="SHORTCUT ICON" href="' . request()->url_for('images/common/favicon_1.ico') . '" />';

    my $base_dir = Mojo::URL->new(BOM::Config::Runtime->instance->app_config->cgi->backoffice->static_url);
    $base_dir->path('css/');
    print '<link rel="stylesheet" type="text/css" href="' . $base_dir->to_string . $_ . '"/>'
        for ('style.css', 'sell_popup.css', 'external/grid.css', 'external/jquery-ui.custom.css');

    foreach my $js_file (BOM::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }

    print '</head>';
    print '<div class="EN" id="language_select" style="display:none"><span class="langsel">English</span></div>';
    print
        '<body class="BlueTopBack" marginheight="0" marginwidth="0" topmargin="0" bottommargin="0" leftmargin="0" rightmargin="0" style="margin:0px;">';

    my $staff = BOM::Backoffice::Auth0::check_staff() ? BOM::Backoffice::Auth0::check_staff()->{nickname} : '';

    print "

        <script>
            dataLayer = [{
                'staff': '$staff'
          }];
        </script>

        <!-- Google Tag Manager -->
        <noscript><iframe src=\"//www.googletagmanager.com/ns.html?id=GTM-N4HNTG\"
        height=\"0\" width=\"0\" style=\"display:none;visibility:hidden\"></iframe></noscript>
        <script>(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':
        new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],
        j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src=
        '//www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);
        })(window,document,'script','dataLayer','GTM-N4HNTG');</script>
        <!-- End Google Tag Manager -->
    ";

    if (not $noDisplayOfTopMenu) {
        vk_BOtopPRES();
    }

    if ($Title) {
        print "<br><center><font class=\"whitetop\"><b>$Title $title_description</b></font></center><br>";
    }
    return;
}

#
# Make a sub-section
# Note : this code doesn't close the table it creates
# If you are re-writing this code, make sure the table opening/closing tags remain the same as they are now
#
sub Bar {
    my ($bartext) = @_;

    $bartext = uc($bartext);

    BarEnd();    #see sub below

    print qq~
 <table class="BlackCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="97%">
  <tbody>
   <tr class="Blacklabel">
    <td class="whitelabel" colspan="2">$bartext</td>
   </tr>
   <tr>
    <td align="left" style="padding: 10px;">~;

    $vk_BarIsDoneOnce = 'yes';
    return;
}

sub BarEnd {
    if (not $vk_BarIsDoneOnce) { return; }
    print '</td></tr></table>';
    return;
}

sub ServerWarningBar {
    #log out
    print qq~
 <table width=100\% cellpadding="0" cellspacing="0">
 <tr><td>
 </td><td>~;

    my $ipmessage = "Your IP: $ENV{'REMOTE_ADDR'}";

    if (BOM::Config::on_qa()) {
        my $url = request()->url_for('backoffice/login.cgi?backprice=');
        my ($c, $h) = BOM::Backoffice::Cookie::get_cookie('backprice') ? ('YES', $url . '0') : ('NO', $url . '1');

        $ipmessage .= qq{, backprice config: <a href="$h">$c</a>};
    }

    my $topbarbackground = '#0000BB';

    print qq~
 <table width="100%" cellpadding="4" cellspacing="0" border="0">
 <tr><td width="100%" bgcolor="$topbarbackground" align="center"><font class="whitetop">
 <b>$ipmessage</b></font>
 </td></tr></table>
 </td></tr><tr>
 <td colspan="2" style="background-repeat: repeat-x;" background="~
        . request()->url_for('images/topborder.gif', undef, undef, {internal_static => 1}) . qq~">
 <img src="~ . request()->url_for('images/blank.gif', undef, undef, {internal_static => 1}) . qq~" height="16" width="1"></td>
 </tr></table>~;
    return;
}

#### THE FOLLOWING (vk) SUBS ARE THE INTERFACE DESIGN OF B/O

sub vk_BOtopPRES    #this sub executed in BrokerPresentation
{
    my $broker = request()->broker_code;

    my $rand           = '?' . rand(9999);                                                   #to avoid caching on these fast navigation links
    my $vk_BOurl       = request()->url_for("backoffice/f_broker_login.cgi", {_r => $rand});
    my $vk_BOmenuWidth = 100;                                                                #width of the left menu (change if some urls doesn't fit)

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

    my $vk_BOmenuWidth2 = $vk_BOmenuWidth + 55;
    print qq~
	<table border="0" width="100%" cellspacing="0" cellpadding="0">
	<tr>
	<td valign="top" height="100%" class="BlueMenuBack">
		<table border="0" cellpadding="1" cellspacing="0" width="$vk_BOmenuWidth2">
			<tr>
				<td valign="top" class="BlueMenuBack" height="100%">
					<table align="center" border="0" cellpadding="0" cellspacing="0" width="$vk_BOmenuWidth">
						<tbody>
							<tr>
								<td><img src="~ . request()->url_for('images/xpicon1.gif', undef, undef, {internal_static => 1}) . qq~" height="32" width="31"></td>
								<td valign="bottom"><img src="~
        . request()->url_for('images/xptitle.gif', undef, undef, {internal_static => 1}) . qq~" height="25" width="110"></td>
								<td valign="bottom"><img src="~
        . request()->url_for('images/xpexpand1.gif', undef, undef, {internal_static => 1}) . qq~" height="25" width="25"></td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_broker_login.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Login Page</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_bo_enquiry.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Transaction Reports</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_accountingreports.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Accounting Reports</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_manager.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Deposits & Withdrawals</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_clientloginid.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Client Management</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/login.cgi',
        {
            _r       => $rand,
            whattodo => 'logout'
        })
        . qq~" class="Blue" style="margin-left: 10px;">Log Out</a>
								</td>
							</tr>
							<tr>
								<td colspan="3" class="StyleNameV" style="padding-left: 5px;" bgcolor="#6375d6" width="$vk_BOmenuWidth">MISC. TOOLS</td>
							</tr>
							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_investigative.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Investigative Tools</a>
								</td>
							</tr>

							<tr>
								<td colspan="3" class="ParamTblCell" style="padding-bottom: 3px; padding-top: 3px;" width="$vk_BOmenuWidth">
									<a href="~
        . request()->url_for(
        'backoffice/f_client_anonymization.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Client Anonymization</a>
								</td>
							</tr>
      </tbody>
     </table>
    </td>
   </tr>
  </table>
 </td>
 <td width="100%" valign="top" align="center">~;
    $vk_didBOtopPRES = 'yes';
    return;
}

sub vk_BObottomPRES {
    if (not $vk_didBOtopPRES) { return; }

    print "<br><br></td></tr></table>";    #Eventually can be more different stuff here

    ServerWarningBar();
    return;
}

sub code_exit_BO {
    my ($message) = @_;
    print $message if $message;
    if ($vk_BarIsDoneOnce) { BarEnd(); }             #backoffice closing bar output (must be before vk_BObottomPRES)
    if ($vk_didBOtopPRES)  { vk_BObottomPRES(); }    #backoffice closing presentation
    no strict "refs";                                ## no critic (ProhibitNoStrict, ProhibitProlongedStrictureOverride)
    undef ${"main::vk_BarIsDoneOnce"};
    undef ${"main::vk_didBOtopPRES"};
    BOM::Backoffice::Request::request_completed();
    exit 0;
}
1;

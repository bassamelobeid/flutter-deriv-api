###############################################################################################
#
#                            subs_presentation_backoffice
#
# This module contains the presentation routines of the BACKOFFICE
#
###############################################################################################
use strict 'vars';
use BOM::Platform::Runtime;
use BOM::Platform::Context;
use Mojo::URL;
use BOM::View::JavascriptConfig;
use BOM::Platform::Plack qw( AjaxSession );
use BOM::Platform::Sysinit ();

our ($vk_BarIsDoneOnce, $vk_didBOtopPRES,);

# "Header" of the backoffice pages
sub BrokerPresentation {
    my ($Title, $title_description, $noDisplayOfTopMenu, $outputtype) = @_;

    if (AjaxSession() or $outputtype =~ /csv/ or request()->param('printable')) {
        return;
    }

    print '<html>';
    print '<head>';
    print '<title>' . uc(BOM::Platform::Runtime->instance->hosts->localhost->canonical_name) . "-$Title-$ENV{REMOTE_ADDR}</title>";
    print '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">';
    print '<link rel="SHORTCUT ICON" href="' . request()->url_for('images/common/favicon_1.ico') . '" />';
    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/style.css',         undef, undef, {internal_static => 1}) . '"/>';
    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/sell_popup.css',    undef, undef, {internal_static => 1}) . '"/>';
    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/external/grid.css', undef, undef, {internal_static => 1}) . '"/>';
    print '<link rel="stylesheet" type="text/css" href="' . request()->url_for('css/jquery-ui.custom.css') . '"/>';

    BOM::Platform::Context::template->process('backoffice/global/javascripts.html.tt',
        {javascript => BOM::View::JavascriptConfig->instance->config_for()})
        || die BOM::Platform::Context::template->error;

    foreach my $js_file (BOM::View::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }

    print '</head>';
    print '<div class="EN" id="language_select" style="display:none"><span class="langsel">English</span></div>';
    print
        '<body class="BlueTopBack" marginheight="0" marginwidth="0" topmargin="0" bottommargin="0" leftmargin="0" rightmargin="0" style="margin:0px;">';

    if (not $noDisplayOfTopMenu) {
        vk_BOtopPRES();
    }

    if ($Title) {
        print "<br><center><font class=\"whitetop\"><b>$Title $title_description</b></font></center><br>";
    }
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
    <td align="left" style="padding-left: 10px;">~;

    $vk_BarIsDoneOnce = 'yes';
}

sub BarEnd {
    if (not $vk_BarIsDoneOnce) { return; }
    print '</td></tr></table>';
}

sub ServerWarningBar {
    my $brokercodesonthisserver;

    #log out
    print qq~
 <table width=100\% cellpadding="0" cellspacing="0">
 <tr><td>
 </td><td>~;

    my $switchservers = "<b>You are on " . BOM::Platform::Runtime->instance->hosts->localhost->canonical_name . "</b><br/>";

    my $runtime = BOM::Platform::Runtime->instance;
    my @bconserver = map { $_->code } $runtime->broker_codes->all;

    if (@bconserver) {
        $brokercodesonthisserver = "Your IP: $ENV{'REMOTE_ADDR'} - Bcodes : ";
        foreach my $br (sort @bconserver) {
            if ($br ne request()->broker_code) {
                my $url = Mojo::URL->new($ENV{'REQUEST_URI'});
                if ($url->path =~ /backoffice\/(.*)?/) {
                    $url->query(['broker' => $br]);
                    $brokercodesonthisserver .= "<a href='" . request()->url_for("backoffice/$1", $url->query) . "'>$br</a> ";
                }
            } else {
                $brokercodesonthisserver .= "$br ";
            }
        }
    }

    my $topbarbackground;
    my $systemisoff;
    if (BOM::Platform::Runtime->instance->app_config->system->suspend->system) {
        $topbarbackground = '#FF0000';
        $systemisoff      = " <font size=3>*** SYSTEM IS OFF ***</font> ";
    } elsif (BOM::Platform::Runtime->instance->app_config->system->on_development) {
        $topbarbackground = '#BBBB00';
    } elsif (BOM::Platform::Runtime->instance->hosts->localhost->has_role('ui_server')) {
        $topbarbackground = '#000077';
    } else {
        $topbarbackground = '#0000BB';
    }

    print qq~
 <table width="100%" cellpadding="4" cellspacing="0" border="0">
 <tr><td width="100%" bgcolor="$topbarbackground" align="center"><font class="whitetop">
 $switchservers<b>$systemisoff $brokercodesonthisserver $systemisoff</b></font>
 </td></tr></table>
 </td></tr><tr>
 <td colspan="2" style="background-repeat: repeat-x;" background="~
        . request()->url_for('images/topborder.gif', undef, undef, {internal_static => 1}) . qq~">
 <img src="~ . request()->url_for('images/blank.gif', undef, undef, {internal_static => 1}) . qq~" height="16" width="1"></td>
 </tr></table>~;
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
        'backoffice/f_rtquoteslogin.cgi',
        {
            _r     => $rand,
            broker => $broker
        })
        . qq~" class="Blue" style="margin-left: 10px;">Realtime Feeds</a>
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
      </tbody>
     </table>
    </td>
   </tr>
  </table>
 </td>
 <td width="100%" valign="top" align="center">~;
    $vk_didBOtopPRES = 'yes';
}

sub vk_BObottomPRES {
    if (not $vk_didBOtopPRES) { return; }

    print "<br><br></td></tr></table>";    #Eventually can be more different stuff here

    ServerWarningBar();
}

sub code_exit_BO {
    if ($vk_BarIsDoneOnce) { BarEnd(); }             #backoffice closing bar output (must be before vk_BObottomPRES)
    if ($vk_didBOtopPRES)  { vk_BObottomPRES(); }    #backoffice closing presentation

    BOM::Platform::Sysinit::code_exit();
}
1;

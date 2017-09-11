#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings
use open qw[ :encoding(UTF-8) ];

use Text::Trim;
use Text::Diff;
use Path::Tiny;
use HTML::Entities;

use f_brokerincludeall;
use Date::Utility;
use BOM::Platform::Config;
use Quant::Framework::InterestRate;
use BOM::Backoffice::Request qw(request);
use Quant::Framework::ImpliedRate;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::Display::VolatilitySurface;
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::MarketData qw(create_underlying);
use BOM::Backoffice::Sysinit ();
use BOM::Platform::AuditLog;
BOM::Backoffice::Sysinit::init();

PrintContentType();

local $\ = "\n";

my $text              = request()->param('text');
my $filen             = request()->param('filen');
my $vol_update_symbol = request()->param('symbol');
my $can_delete;

# Check file name
my $ok = 0;
my $overridefilename;

my $file_broker_code;
my @removed_lines = ();

if ($filen eq 'editvol') { $ok = 1; }
if ($filen =~ m!^vol/master\w{3}(?:-\w{3})?\.interest$!) { $ok = 1; }

if ($ok == 0) {
    print "Wrong file<P>";
    code_exit_BO();
}

unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Platform::Config::node()->{node}->{roles}})) {
    print "Sorry, files cannot be saved on this server because it is not the Master Server.";
    code_exit_BO();
}

my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

$text =~ s/\r\n/\n/g;
$text =~ s/\n\r/\n/g;

my @lines = split(/\n/, $text);

my $ON_expiry_date;

if ($filen eq 'editvol') {
    my $underlying = create_underlying($vol_update_symbol);
    my $market     = $underlying->market->name;
    my $model =
        ($underlying->volatility_surface_type eq 'moneyness')
        ? 'Quant::Framework::VolSurface::Moneyness'
        : 'Quant::Framework::VolSurface::Delta';

    my $surface_data   = {};
    my $col_names_line = shift @lines;
    my @points         = split /\s+/, $col_names_line;
    shift @points;    # get rid of "day" label

    foreach my $smile_line (@lines) {
        my @pieces = split /\s+/, $smile_line;
        my %smile;
        my $day = shift @pieces;
        my %spread;
        foreach my $point (@points) {
            if ($point =~ /D_spread/) {
                my $spread_point = $point;
                $spread_point =~ s/D_spread//g;
                $spread{$spread_point} = shift @pieces;
            } elsif ($point =~ /M_spread/) {
                my $spread_point = $point;
                $spread_point =~ s/M_spread//g;
                $spread{$spread_point} = shift @pieces;
            } else {
                $smile{$point} = shift @pieces;
            }

        }

        # last piece is the expiry date if present
        my $expiry_date = @pieces ? $pieces[0] : undef;
        $surface_data->{$day} = {
            smile      => \%smile,
            vol_spread => \%spread,
            ($expiry_date ? (expiry_date => $expiry_date) : ()),
        };

        $ON_expiry_date = Date::Utility->new($expiry_date)->truncate_to_day if $day eq 'ON'; 
    }
    my %surface_args = (
        underlying       => $underlying,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        surface          => $surface_data,
        creation_date    => Date::Utility->new,
        (request()->param('spot_reference') ? (spot_reference => request()->param('spot_reference')) : ()),
    );
    my $existing_surface_args = {
        underlying => $underlying,
    };
    my $surface = $model->new(%surface_args);

    my $dm                  = BOM::MarketData::Fetcher::VolSurface->new;
    my $existing_volsurface = $dm->fetch_surface($existing_surface_args);
    my $existing_surface    = eval { $existing_volsurface->surface };
    $existing_volsurface = undef unless $existing_surface;

    if ($existing_volsurface) {
        my ($big_differences, $error_message, @output) =
            BOM::MarketData::Display::VolatilitySurface->new(surface => $surface)->print_comparison_between_volsurface({
                ref_surface => $existing_volsurface,
                warn_diff   => 1,
                quiet       => 1,
            });

        print "<P> Difference between existing and new surface </p>";
        print @output;

        if ( $ON_expiry_date->is_same_as(Date::Utility->new->trucate_to_day)) {
	    print "<P> Overnigh expiry date cannot be the same date as today.</P>";
        } elsif (!$surface->is_valid) {
            print "<P> " . encode_entities($surface->validation_error) . " </P>";

        } elsif ($big_differences) {
            print "<P>" . encode_entities($error_message) . "</P>";
        } else {
            print "<P>Surface for " . encode_entities($vol_update_symbol) . " being saved</P>";
            $surface->save;
        }
    }

    code_exit_BO();
}

if ($filen =~ m!^vol/master(\w{3}(?:-\w{3})?)\.interest$!) {
    my $symbol = $1;
    my $rates  = {};

    foreach my $rateline (@lines) {
        my $err_cond;
        $rateline = rtrim($rateline);

        my ($tenor, $rate);
        if ($rateline =~ /^(\d+)\s+(\-?\d*\.?\d*)/) {
            $tenor = $1;
            $rate  = $2;
            if ($tenor == 0 or $tenor < 1 or $tenor > 733) {
                $err_cond = 'improper days (' . $tenor . ')';
            } elsif ($rate <= -2) {
                $err_cond = 'too low rate (' . $rate . ')';
            } elsif ($rate > 20) {
                $err_cond = 'too high rate (' . $rate . ')';
            }
        } else {
            $err_cond = 'malformed line';
        }

        if ($err_cond) {
            print '<P><font color=red><B>ERROR with '
                . encode_entities($err_cond)
                . ' on line  ['
                . encode_entities($rateline)
                . '].  File NOT saved.</B></font></P>';
            code_exit_BO();
        } else {
            $rates->{$tenor} = $rate;
        }
    }

    my $class = 'Quant::Framework::InterestRate';
    $class = 'Quant::Framework::ImpliedRate' if $symbol =~ /-/;

    my $rates_obj = $class->new(
        symbol           => $symbol,
        rates            => $rates,
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
    $rates_obj->save;
}

if (not $overridefilename) {
    my $db_loc = BOM::Platform::Runtime->instance->app_config->system->directory->db;
    if ($filen =~ /^market/) {
        $db_loc = BOM::Platform::Runtime->instance->app_config->system->directory->feed;
    }
    $overridefilename = $db_loc . '/' . $filen;
}

if (request()->param('deletefileinstead') eq 'on' and $can_delete) {
    unlink $overridefilename;
    if (-e $overridefilename) {
        print "ERROR! FILE COULD NOT BE DELETED!!";
        code_exit_BO();
    }
    print "Success.  File has been deleted.";
    code_exit_BO();
}

my $diff;
if (-e $overridefilename) {
    $diff = Text::Diff::diff \$text, $overridefilename, {STYLE => "Table"};
} else {
    $diff = '[File is a new file]';
}

# Save the file
my $fage = (-M $overridefilename) * 24 * 60 * 60;

# a feed file
if (    -e $overridefilename
    and $fage < 30
    and not BOM::Platform::Config::on_qa
    and $overridefilename !~ /\/combined\//)
{
    print "<P><font color=red>Problem!! The file has been saved by someone else within the last $fage seconds.
	There is a risk that that person saved modifications that you are going to over-write!
	Please click Back, then REFRESH THE PAGE to pull in the modifications, then make your changes again, then re-save.";
    code_exit_BO();
}

#internal audit warnings
if ($filen eq 'f_broker/promocodes.txt' and not BOM::Platform::Config::on_qa and $diff) {
    warn("promocodes.txt EDITED BY $clerk");
    my $brand = Brands->new(name => request()->brand);
    send_email({
            from    => $brand->emails('system'),
            to      => $brand->emails('compliance'),
            subject => "Promotional Codes edited by $clerk",
            message => ["$ENV{'REMOTE_ADDR'}\n$ENV{'HTTP_USER_AGENT'} \nDIFF=\n$diff", '================', 'NEW FILE=', @lines]});
}

open(my $fh, ">", "$overridefilename")
    || die "[$0] Cannot open $overridefilename to write $!";
flock($fh, 2);
local $\ = "\n";

foreach my $l (@lines) {
    print $fh $l;
}
close($fh)
    || die "[$0] Cannot close $overridefilename $!";

# Log the difference (difflog)
save_difflog({
    'overridefilename' => $overridefilename,
    'loginID'          => $broker,
    'staff'            => $clerk,
    'diff'             => $diff,
});

# Log the difference (staff.difflog)
save_log_staff_difflog({
    'overridefilename' => $overridefilename,
    'loginID'          => $broker,
    'staff'            => $clerk,
    'diff'             => $diff,
});

# f_save complete log
save_log_save_complete_log({
    'overridefilename' => $overridefilename,
    'loginID'          => $broker,
    'staff'            => $clerk,
    'diff'             => $diff,
});

BOM::Platform::AuditLog::log("$broker $clerk $ENV{'REMOTE_ADDR'} $overridefilename newsize=" . (-s $overridefilename), '', $clerk);

# DISPLAY SAVED FILE
print "<b><p>FILE was saved as follows :</p></b><br>";
my $shorttext = substr($text, 0, 1000);

print "<pre>" . encode_entities($shorttext);
if (length $shorttext != length $text) {
    print "....etc.......";
}
print "</pre>";

print "<p>New file size is " . encode_entities(-s "$overridefilename") . " bytes</p><hr/>";

# DISPLAY diff
print
    "<hr><table border=0><tr><td bgcolor=#ffffce><center><b>DIFFERENCES BETWEEN OLD FILE AND NEW FILE :<br>(differences indicated by stars)</b><br><pre>"
    . encode_entities($diff)
    . "</pre></td></tr></table><hr>";

if (-e "$overridefilename.staffedit") {
    unlink "$overridefilename.staffedit";
}

# Send email to quant team
my $message;
my $dbloc = BOM::Platform::Runtime->instance->app_config->system->directory->db;
$diff =~ s/$dbloc//;
unless ($diff eq '0') {
    if ($filen =~ /^market/) {
        $message = "FILE $filen CHANGED ON SERVER BY $clerk\n\nDIFFERENCES BETWEEN OLD FILE AND NEW FILE :\n$diff\n";
    }
}
if ($message and not BOM::Platform::Config::on_qa) {
    warn("FILECHANGED : File $filen edited by $clerk : $message");
}

code_exit_BO();

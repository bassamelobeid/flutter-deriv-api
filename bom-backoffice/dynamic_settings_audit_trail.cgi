#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use Scalar::Util             qw(looks_like_number);
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use Locale::Country;
use BOM::Config;
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use Text::Trim;
use BOM::Config::Chronicle;

my $authorisations = BOM::DynamicSettings::AUTHORISATIONS();
my $cgi            = CGI->new;

PrintContentType();

my $setting = request->params->{setting} // 'none';
my ($section, $name) = split(/\./, $setting);
my $groups = $authorisations->{$section} // [];

code_exit_BO('<p class="error"><b>Access denied</b></p>')
    unless $name && scalar @$groups && BOM::Backoffice::Auth::has_authorisation($groups);

my $type = BOM::Config::Runtime->instance->app_config->get_data_type($setting);

BrokerPresentation('DYNAMIC SETTINGS AUDIT TRAIL - ' . $setting);
#Bar('DYNAMIC SETTINGS AUDIT TRAIL');

my $offset = request->params->{offset} // 0;
$offset = 0 unless looks_like_number($offset) and $offset >= 0;
my $limit = 100;
my $more;

my $dbic = BOM::Config::Chronicle::dbic();

my $rows = $dbic->run(
    fixup => sub {
        $_->selectall_arrayref("SELECT * FROM get_app_settings_history(?, ?, ?)", {Slice => {}}, $setting, $limit + 1, $offset);
    });

if (@$rows > $limit) {
    $more = 1;
    pop @$rows;
}

my (@history, %cols);
my $json = JSON->new->allow_nonref;
$json->canonical([1]);
for my $row (@$rows) {
    my $val = decode_json($row->{value});
    my $data;
    if ($type eq 'json_string' && ref decode_json($val->{data}) eq 'HASH') {
        $data = decode_json($val->{data});

        for my $key (keys %$data) {
            $cols{$key} = 1;
            $data->{$key} = $json->encode($data->{$key}) if ref($data->{$key});
        }
    } else {
        $data->{Value} = $val->{data};
        $cols{value} = 1;
    }
    push @history,
        {
        stamp => $row->{stamp},
        staff => $val->{staff},
        data  => $data
        };
}

BOM::Backoffice::Request::template()->process(
    'backoffice/dynamic_settings_audit_trail.html.tt',
    {
        $more       ? (next => $offset + $limit) : (),
        $offset > 0 ? (prev => $offset - $limit) : (),
        setting  => $setting,
        referrer => request->params->{referrer},
        history  => \@history,
        cols     => [sort keys %cols],
    });

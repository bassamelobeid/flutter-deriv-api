#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no indirect;

use open qw[ :encoding(UTF-8) ];
use Format::Util::Strings qw( set_selected_item );
use HTML::Entities;
use Syntax::Keyword::Try;
use Date::Utility;
use LandingCompany::Registry;
use Syntax::Keyword::Try;
use Data::Validate::Sanctions;

use f_brokerincludeall;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Config::Compliance;
use BOM::Config::Chronicle;
use BOM::DynamicSettings;
use BOM::Config;
use BOM::Config::Redis;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("COMPLIANCE DASHBOARD");

my ($thresholds, $jurisdiction_rating);
my $thresholds_readonly = not BOM::Backoffice::Auth0::has_authorisation(['IT']);
my $compliance_config   = BOM::Config::Compliance->new;

my $what_to_do = request()->param('whattodo') // '';

if (!$thresholds_readonly && $what_to_do =~ qr/^save_thresholds_(\w+)_(\w+)$/) {
    my ($type, $landing_company) = ($1, $2);

    $thresholds->{$type} = $compliance_config->get_risk_thresholds($type);
    delete $thresholds->{$type}->{revision};

    my %values = ();
    for my $threshold (BOM::Config::Compliance::RISK_THRESHOLDS) {
        my $name  = $threshold->{name};
        my $value = request()->param("$landing_company.$name") || undef;

        $values{$name} = $value if $value;
    }
    $thresholds->{$type}->{$landing_company} = \%values;

    my $revision = request()->param("revision");
    try {
        my $data = $compliance_config->validate_risk_thresholds($type, $thresholds->{$type}->%*);

        BOM::DynamicSettings::save_settings({
                settings => {
                    revision                             => $revision,
                    "compliance.${type}_risk_thresholds" => encode_json_utf8($data)
                },
                settings_in_group => ["compliance.${type}_risk_thresholds"],
                save              => 'global',
            });
        # let thresholds be reloaded after successful save
        undef $thresholds->{$type};
    } catch ($e) {
        print "<p class=\"error\">Error: $e </p>";
        $thresholds->{$type}->{revision} = $revision;
    };
} elsif ($what_to_do =~ qr/^save_jurisdiction_risk_rating_(\w+)_(\w+)$/) {
    my ($type, $landing_company) = ($1, $2);

    $jurisdiction_rating->{$type} = $compliance_config->get_jurisdiction_risk_rating($type);
    delete $jurisdiction_rating->{$type}->{revision};

    for my $risk_level (BOM::Config::Compliance::RISK_LEVELS) {
        my $value = request()->param("$landing_company.$risk_level") // '';

        $jurisdiction_rating->{$type}->{$landing_company}->{$risk_level} = [split ' ', $value];
    }

    my $revision = request()->param("revision") // '';
    try {
        my $result = $compliance_config->validate_jurisdiction_risk_rating($type, $jurisdiction_rating->{$type}->%*);

        BOM::DynamicSettings::save_settings({
                settings => {
                    revision                                      => $revision,
                    "compliance.${type}_jurisdiction_risk_rating" => encode_json_utf8($result),
                },
                settings_in_group => ["compliance.${type}_jurisdiction_risk_rating"],
                save              => 'global',
            });

        $jurisdiction_rating->{$type} = undef;
    } catch ($e) {
        print '<p class="error"> ' . encode_entities($e) . '</p>';
        $jurisdiction_rating->{$type}->{revision} = $revision;
    }
}

$thresholds->{$_}          //= $compliance_config->get_risk_thresholds($_)          for qw/aml mt5/;
$jurisdiction_rating->{$_} //= $compliance_config->get_jurisdiction_risk_rating($_) for qw/aml mt5/;

my $show_landing_company = sub {
    my ($type, $landing_company) = @_;
    my $is_mt5 = $type eq 'mt5';

    # Compliance team insists to show broker codes CR and MF rather than landing company names svg and maltainvest
    my $lc_display_name = $is_mt5 ? $landing_company->short : $landing_company->broker_codes->[0];

    BOM::Backoffice::Request::template()->process(
        'backoffice/aml_risk_settings.html.tt',
        {
            url             => request()->url_for('backoffice/compliance_dashboard.cgi'),
            type            => $type,
            landing_company => $landing_company->short,
            lc_display_name => $lc_display_name,
            is_mt5          => $is_mt5,
            thresholds      => $thresholds->{$type},
            jurisdiction    => $jurisdiction_rating->{$type},
            threshold_names => [BOM::Config::Compliance::RISK_THRESHOLDS],
            risk_levels     => [BOM::Config::Compliance::RISK_LEVELS],
            is_readonly     => $thresholds_readonly,
        }) || die BOM::Backoffice::Request::template()->error() . "\n";
};

my @all_landing_companies = LandingCompany::Registry->get_all();

Bar('AML Risk Settings');
print '<table>';
for my $landing_company (@all_landing_companies) {
    next if $landing_company eq 'revision';
    next unless $thresholds->{aml}->{$landing_company->short} or $jurisdiction_rating->{aml}->{$landing_company->short};

    $show_landing_company->('aml', $landing_company);
}
print '<tr> <td>'
    . '<p><a class="btn btn--secondary" href="dynamic_settings_audit_trail.cgi?setting=compliance.aml_risk_thresholds&referrer=compliance_dashboard.cgi">See history of threshold changes</a></p>'
    . '</td> <td>'
    . '<p><a class="btn btn--secondary" href="dynamic_settings_audit_trail.cgi?setting=compliance.aml_jurisdiction_risk_rating&referrer=compliance_dashboard.cgi">See history of jurisdiction changes</a></p>'
    . '</td> </tr>';
print '</table>';

Bar('MT5 AML Risk Settings');
print '<table>';
for my $landing_company (@all_landing_companies) {
    next if $landing_company eq 'revision';
    next unless $thresholds->{mt5}->{$landing_company->short} or $jurisdiction_rating->{mt5}->{$landing_company->short};

    $show_landing_company->('mt5', $landing_company);
}

print '<tr> <td>'
    . '<p><a class="btn btn--secondary" href="dynamic_settings_audit_trail.cgi?setting=compliance.mt5_risk_thresholds&referrer=compliance_dashboard.cgi">See history of threshold changes</a></p>'
    . '</td> <td>'
    . '<p><a class="btn btn--secondary" href="dynamic_settings_audit_trail.cgi?setting=compliance.mt5_jurisdiction_risk_rating&referrer=compliance_dashboard.cgi">See history of jurisdiction changes</a></p>'
    . '</td> </tr>';
print '</table>';

Bar("Sanction List Info");
my $sanction_validator = Data::Validate::Sanctions->new(
    storage    => 'redis',
    connection => BOM::Config::Redis::redis_replicated_read());
my %data;
for my $source (keys $sanction_validator->data->%*) {
    my $source_data = $sanction_validator->data->{$source};
    $data{$source}->{name}     = $source;
    $data{$source}->{updated}  = $source_data->{updated} ? Date::Utility->new($source_data->{updated})->date : '-';
    $data{$source}->{count}    = scalar($source_data->{content} // [])->@*;
    $data{$source}->{verified} = $source_data->{verified} ? Date::Utility->new($source_data->{verified})->datetime_yyyymmdd_hhmmss : '-';
    $data{$source}->{error}    = $source_data->{error},;
}
BOM::Backoffice::Request::template()->process('backoffice/sanction_list_info.html.tt', {data => \%data},)
    || die BOM::Backoffice::Request::template()->error() . "\n";

code_exit_BO();

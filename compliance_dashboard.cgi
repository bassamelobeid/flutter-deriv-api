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

use f_brokerincludeall;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Config::Compliance;
use BOM::Config::Chronicle;
use BOM::DynamicSettings;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("COMPLIANCE DASHBOARD");

my ($thresholds, $jurisdiction_rating);
my $thresholds_readonly = not BOM::Backoffice::Auth0::has_authorisation(['IT']);
my $compliance_config   = BOM::Config::Compliance->new;

my $what_to_do = request()->param('whattodo') // '';

if (!$thresholds_readonly && $what_to_do =~ qr/^save_thresholds_(.*)$/) {
    my $type = $1;

    $thresholds->{$type} = $compliance_config->get_risk_thresholds($type);

    delete $thresholds->{$type}->{revision};

    for my $broker (keys $thresholds->{$type}->%*) {
        my %values = ();
        for my $threshold (BOM::Config::Compliance::RISK_THRESHOLDS) {
            my $name  = $threshold->{name};
            my $value = request()->param("$broker.$name") || undef;

            $values{$name} = $value if $value;
        }
        $thresholds->{$type}->{$broker} = \%values;
    }

    my $revision = request()->param("revision_thresholds_$type");
    try {
        my $data = $compliance_config->validate_risk_thresholds($thresholds->{$type}->%*);

        BOM::DynamicSettings::save_settings({
                settings => {
                    revision                             => $revision,
                    "compliance.${type}_risk_thresholds" => encode_json_utf8($data)
                },
                settings_in_group => ["compliance.${type}_risk_thresholds"],
                save              => 'global',
            });
        # let thresholds be reloaded after successful save
        delete $thresholds->{$type};
    } catch ($e) {
        print "<p class=\"error\">Error: $e </p>";
        $thresholds->{$type}->{revision} = $revision;
    };
} elsif ($what_to_do eq 'save_jurisdiction_risk_rating') {
    $jurisdiction_rating = $compliance_config->get_jurisdiction_risk_rating();
    delete $jurisdiction_rating->{revision};

    for my $risk_level (BOM::Config::Compliance::RISK_LEVELS) {
        my $value = request()->param("jurisdiction_risk.$risk_level") // '';

        $jurisdiction_rating->{$risk_level} = [split ' ', $value];
    }

    my $revision = request()->param("jurisdiction_risk_revision") // '';
    try {
        my $result = $compliance_config->validate_jurisdiction_risk_rating(%$jurisdiction_rating);

        BOM::DynamicSettings::save_settings({
                settings => {
                    revision                              => $revision,
                    'compliance.jurisdiction_risk_rating' => encode_json_utf8($result),
                },
                settings_in_group => ['compliance.jurisdiction_risk_rating'],
                save              => 'global',
            });

        $jurisdiction_rating = undef;
    } catch ($e) {
        print '<p class="error"> ' . encode_entities($e) . '</p>';
        $jurisdiction_rating->{revision} = $revision;
    }
}

for my $threshold_type (qw/aml mt5/) {
    Bar(uc($threshold_type) . ' RISK THRESHOLDS');

    my $data     = $thresholds->{$threshold_type} // $compliance_config->get_risk_thresholds($threshold_type);
    my $revision = delete $data->{revision};

    BOM::Backoffice::Request::template()->process(
        'backoffice/transaction_thresholds.html.tt',
        {
            url              => request()->url_for('backoffice/compliance_dashboard.cgi'),
            threshold_type   => $threshold_type,
            data             => $data,
            revision         => $revision,
            broker_codes     => [sort keys %$data],
            threshold_names  => [BOM::Config::Compliance::RISK_THRESHOLDS],
            dynamic_settings => "compliance.${threshold_type}_risk_thresholds",
            is_readonly      => $thresholds_readonly,
        }) || die BOM::Backoffice::Request::template()->error() . "\n";
}

Bar("Jurisdiction Risk Rating");

$jurisdiction_rating //= $compliance_config->get_jurisdiction_risk_rating();
my $revision = delete $jurisdiction_rating->{revision};

BOM::Backoffice::Request::template()->process(
    'backoffice/risk_rating.html.tt',
    {
        url              => request()->url_for('backoffice/compliance_dashboard.cgi'),
        data             => $jurisdiction_rating,
        revision         => $revision,
        risk_levels      => [BOM::Config::Compliance::RISK_LEVELS],
        dynamic_settings => "compliance.jurisdiction_risk_rating",
    }) || die BOM::Backoffice::Request::template()->error() . "\n";

code_exit_BO();

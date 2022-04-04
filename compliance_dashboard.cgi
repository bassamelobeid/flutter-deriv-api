#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use open qw[ :encoding(UTF-8) ];
use Format::Util::Strings qw( set_selected_item );
use HTML::Entities;
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

my $compliance_config = BOM::Config::Compliance->new;

my $what_to_do = request()->param('whattodo') // '';

my $jurisdiction_rating;
if ($what_to_do eq 'save_jurisdiction_risk_rating') {
    $jurisdiction_rating = $compliance_config->get_jurisdiction_risk_rating();

    my $revision = request()->param("jurisdiction_risk_revision") // '';
    $jurisdiction_rating->{revision} = $revision;

    for my $risk_level (BOM::Config::Compliance::RISK_LEVELS) {
        my $value = request()->param("jurisdiction_risk.$risk_level") // '';

        $jurisdiction_rating->{$risk_level} = [split ' ', $value];
    }

    try {
        my $result = $compliance_config->validate_jurisdiction_risk_rating(%$jurisdiction_rating);
        $jurisdiction_rating->{staff}     = BOM::Backoffice::Auth0::get_staffname();
        $jurisdiction_rating->{timestamp} = time;

        BOM::DynamicSettings::save_settings({
                settings => {
                    revision                              => $revision,
                    'compliance.jurisdiction_risk_rating' => encode_json_utf8($jurisdiction_rating),
                },
                settings_in_group => ['compliance.jurisdiction_risk_rating'],
                save              => 'global',
            });

        $jurisdiction_rating = undef;
    } catch ($e) {
        print '<p class="error"> ' . encode_entities($e) . '</p>';
    }
}

Bar("Jurisdiction Risk Rating");

$jurisdiction_rating //= $compliance_config->get_jurisdiction_risk_rating();

my $revision  = delete $jurisdiction_rating->{revision};
my $staff     = delete $jurisdiction_rating->{staff};
my $timestamp = Date::Utility->new(delete $jurisdiction_rating->{timestamp})->datetime_yyyymmdd_hhmmss;

BOM::Backoffice::Request::template()->process(
    'backoffice/risk_rating.html.tt',
    {
        url         => request()->url_for('backoffice/compliance_dashboard.cgi'),
        data        => $jurisdiction_rating,
        revision    => $revision,
        staff       => $staff,
        timestamp   => $timestamp,
        risk_levels => [BOM::Config::Compliance::RISK_LEVELS],
    }) || die BOM::Backoffice::Request::template()->error() . "\n";

code_exit_BO();

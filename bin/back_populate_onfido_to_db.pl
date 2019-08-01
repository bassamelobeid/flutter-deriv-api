#!/etc/rmg/bin/perl

use strict;
use warnings;

use Data::Dumper;

use YAML::XS qw(LoadFile Load);
use IO::Async::Loop;
use Future::AsyncAwait;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util qw(min);
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Event::Services;
use Getopt::Long;
use Log::Any qw($log);
use WebService::Async::Onfido;
use Path::Tiny qw(path);
use BOM::User;
use Locale::Codes::Country qw(country_code2code);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s'               => \my $log_level,
    'requests_per_minute=s' => \my $requests_per_minute,
) or die;

$log_level           ||= 'info';
$requests_per_minute ||= 30;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

my $loop = IO::Async::Loop->new;

$loop->add(my $services = BOM::Event::Services->new);

{
    sub _onfido {
        $services->add_child(my $service = WebService::Async::Onfido->new(token => BOM::Config::third_party()->{onfido}->{authorization_token}, requests_per_minute => $requests_per_minute));
        return $service;
    }
}

# Conversion from our database to the Onfido available fields
my %ONFIDO_DOCUMENT_TYPE_MAPPING = (
    passport                                     => 'passport',
    certified_passport                           => 'passport',
    selfie_with_id                               => 'live_photo',
    driverslicense                               => 'driving_licence',
    cardstatement                                => 'bank_statement',
    bankstatement                                => 'bank_statement',
    proofid                                      => 'national_identity_card',
    vf_face_id                                   => 'live_photo',
    vf_poa                                       => 'unknown',
    vf_id                                        => 'unknown',
    address                                      => 'unknown',
    proofaddress                                 => 'unknown',
    certified_address                            => 'unknown',
    docverification                              => 'unknown',
    certified_bank_details                       => 'unknown',
    professional_uk_high_net_worth               => 'unknown',
    amlglobalcheck                               => 'unknown',
    employment_contract                          => 'unknown',
    power_of_attorney                            => 'unknown',
    notarised                                    => 'unknown',
    frontofcard                                  => 'unknown',
    professional_uk_self_certified_sophisticated => 'unknown',
    experianproveid                              => 'unknown',
    backofcard                                   => 'unknown',
    tax_receipt                                  => 'unknown',
    payslip                                      => 'unknown',
    alldocs                                      => 'unknown',
    professional_eu_qualified_investor           => 'unknown',
    misc                                         => 'unknown',
    other                                        => 'unknown',
);

# Mapping to convert our database entries to the 'side' parameter in the
# Onfido API
my %ONFIDO_DOCUMENT_SIDE_MAPPING = (
    front => 'front',
    back  => 'back',
    photo => 'photo',
);
my $onfido  = _onfido();
my $handler = async sub {
    my ($applicant) = @_;

    my $applicant_id = $applicant->id;
    try {
        my @checks = await $applicant->checks->as_list;
        # Skip data if applicant has no check
        $log->debugf('Skip data because there is no check for applicant %s', $applicant_id);
        return unless (@checks);

        # Get loginid from check tags to create client object for binary_user_id and place_of_birth
        my ($loginid) = map { /^([A-Z]{1,4}\d+)$/ } $checks[0]->tags->@*;
        die ("No loginid detected for $applicant_id with tags ".join(',',$checks[0]->tags->@*)) unless ($loginid);
        $log->debugf('Extract loginid %s from tags ( %s )', $loginid, join(', ', $checks[0]->tags->@*));
        my $client = BOM::User::Client->new({loginid => $loginid})
            or die ("Could not instantiate client for applicant_id: $applicant_id with login ID: $loginid\n");

        $log->debugf('Insert applicant data for user %s and applicant id %s', $client->binary_user_id, $applicant_id);
        my $dbic = $client->db->dbic;
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select betonmarkets.add_onfido_applicant(?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::BIGINT)',
                    undef, $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
                    $applicant->href, $client->binary_user_id
                );
            });
        my @documents = await $onfido->document_list(applicant_id => $applicant_id)->as_list;

        foreach my $doc (@documents) {
            # NOTE that this is very dependent on our current filename format
            my (undef, $type, $side, $file_type) = split /\./, $doc->file_name;
            $type = $ONFIDO_DOCUMENT_TYPE_MAPPING{$type} // 'unknown';
            $side =~ s{^\d+_?}{};
            $side = $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
            $type = 'live_photo' if $side eq 'photo';

            $log->debugf('Insert document data for user %s and document id %s', $client->binary_user_id, $doc->id);
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select betonmarkets.add_onfido_document(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                        undef,
                        $doc->id,
                        $applicant->id,
                        Date::Utility->new($doc->created_at)->datetime_yyyymmdd_hhmmss,
                        $doc->href,
                        $doc->download_href,
                        $type,
                        $side,
                        uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
                        $doc->file_name,
                        $doc->file_type,
                        $doc->file_size
                    );
                });
        }
        
        my @live_photos = await $onfido->photo_list(applicant_id => $applicant_id)->as_list;
        
        foreach my $photo (@live_photos) {
            $log->debugf('Insert live photo data for user %s and document id %s', $client->binary_user_id, $photo->id);
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select betonmarkets.add_onfido_live_photo(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                        undef,
                        $photo->id,
                        $applicant->id,
                        Date::Utility->new($photo->created_at)->datetime_yyyymmdd_hhmmss,
                        $photo->href,
                        $photo->download_href,
                        $photo->file_name,
                        $photo->file_type,
                        $photo->file_size
                    );
                });
            
        }

        foreach my $check (@checks) {
            $log->debugf('Insert check data for user %s and check id %s', $client->binary_user_id, $check->id);
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select betonmarkets.add_onfido_check(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT[])',
                        undef,
                        $check->id,
                        $applicant_id,
                        Date::Utility->new($check->created_at)->datetime_yyyymmdd_hhmmss,
                        $check->href,
                        $check->type,
                        $check->status,
                        $check->result,
                        $check->results_uri,
                        $check->download_uri,
                        $check->tags
                    );
                });

            my @all_report = await $check->reports->as_list;
            for my $report (@all_report) {
                $log->debugf('Insert report data for user %s and report id %s', $client->binary_user_id, $report->id);
                $dbic->run(
                    fixup => sub {
                        my $sth = $_->do(
                            'select betonmarkets.add_onfido_report(?::TEXT, ?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::JSONB, ?::JSONB)',
                            undef,
                            $report->id,
                            $check->id,
                            $report->name,
                            Date::Utility->new($report->created_at)->datetime_yyyymmdd_hhmmss,
                            $report->status,
                            $report->result,
                            $report->sub_result,
                            $report->variant,
                            encode_json_utf8($report->breakdown),
                            encode_json_utf8($report->properties));
                    });
            }
        }
    }
    catch {
        my $e = $@;
        $log->errorf('Error: %s', $e);
        my $filename = './failed_backpopulate_list.txt';
        open(my $fh, '>>', $filename) or die "Could not open file '$filename' $!";
        print $fh $e;
        close $fh;
    }
};

$onfido->applicant_list->map($handler)->resolve->await;

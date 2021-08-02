#!/etc/rmg/bin/perl
use strict;
use warnings;

# This script checks or deletes customer IO records
# Parameters:
# --check <file.txt>            Checks if login IDs in file.txt have customer.io records,
#                               writes matches to file_checked.csv
# --delete <file_checked.csv>   For all login IDs in file_checked.csv, delete corresponding customer.io records
# --restore <file_checked.csv>  Recreates customer.io records from file_checked.csv,
#                               note that some customer.io metadata (e.g. history) will be lost
# --site_id, --api_key          customer.io API credentials, will use /etc/rmg/third_party.yml if not provided

use Getopt::Long;
use Mojo::URL;
use Mojo::UserAgent;
use JSON::MaybeUTF8 qw(:v1);
use List::Util qw(uniq any);
use Path::Tiny qw(path);
use Text::CSV;
use Time::HiRes;
use File::Basename;
use Log::Any qw($log);
use Log::Any::Adapter 'DERIV';

use BOM::Config;

# rate limit for the API is 10 requests per second (per their CS)
use constant {
    TIMEOUT     => 5,
    REQ_PER_SEC => 10
};

my $ua     = Mojo::UserAgent->new->connect_timeout(TIMEOUT);
my $config = BOM::Config::third_party()->{customerio};
my $csv    = Text::CSV->new({binary => 1});

GetOptions(
    "site_id=s" => \my $site_id,
    "api_key=s" => \my $api_key,
    "check=s"   => \my $chk_file,
    "delete=s"  => \my $del_file,
    "restore=s" => \my $restore_file,
);

$site_id //= $config->{site_id};
$api_key //= $config->{api_key};
die "--site_id and --api_key are required" unless ($site_id and $api_key);

if ($chk_file) {

    my @clientids = path($chk_file)->lines({chomp => 1});
    @clientids = uniq(@clientids);

    my %calls;
    for my $clientid (@clientids) {
        my $url = Mojo::URL->new('https://beta-api.customer.io/v1/api/customers/' . $clientid . '/attributes');
        $url->userinfo("$site_id:$api_key");
        $calls{$clientid} = sub { $ua->get($url) };
    }

    print "Checking Customer IO records...\n";
    my $results = query_slowly(\%calls);

    my %cio_data;
    my @cols;
    for my $found (grep { $results->{$_}->res->code == 200 } keys %$results) {
        my $res = decode_json_utf8($results->{$found}->res->body);
        $cio_data{$found} = $res->{customer}->{attributes};
        $cio_data{$found}->{unsubscribed} = $res->{customer}->{unsubscribed};
        push @cols, grep { $_ ne 'id' } keys %{$cio_data{$found}};
    }

    for my $error (grep { $results->{$_}->res->code != 200 and $results->{$_}->res->code != 404 } sort keys %$results) {
        $log->warnf("Error checking %s: %s", $error, $results->{$error}->res->body);
    }
    my ($name, $path, $suffix) = fileparse($chk_file, qr/\.[^.]*/);
    my $outfile = $path . $name . '_checked.csv';
    @cols = uniq(sort @cols);
    open my $fh, ">:encoding(utf8)", $outfile or die "$outfile: $!";
    $csv->eol("\r\n");
    $csv->print($fh, ['loginid', @cols]);
    for my $clientid (sort keys %cio_data) {
        $csv->print($fh, [$clientid, map { $cio_data{$clientid}->{$_} // '' } @cols]);
    }
    close $fh;
    print scalar(keys %cio_data) . "/" . scalar(@clientids) . " client IDs have Customer IO records; matches written to $outfile\n";

} elsif ($del_file) {

    my @clientids = keys %{load_csv($del_file)};

    my %calls;
    for my $clientid (@clientids) {
        my $url = Mojo::URL->new('https://track.customer.io/api/v1/customers/' . $clientid);
        $url->userinfo("$site_id:$api_key");
        $calls{$clientid} = sub { $ua->delete($url) };
    }

    print "Deleting Customer IO records...\n";
    my $results = query_slowly(\%calls);

    for my $result (grep { $results->{$_}->res->code != 200 } sort keys %$results) {
        $log->warnf("Failed to delete %s (%s)", $result, $results->{$result}->res->code);
    }
    my $success_count = scalar grep { $results->{$_}->res->code == 200 } keys %$results;
    print "$success_count/" . scalar(@clientids) . " Customer IO records deleted\n";

} elsif ($restore_file) {

    my $restore_data = load_csv($restore_file);

    my %calls;
    for my $clientid (keys %$restore_data) {
        my $url = Mojo::URL->new('https://track.customer.io/api/v1/customers/' . $clientid);
        $url->query($restore_data->{$clientid});
        $url->userinfo("$site_id:$api_key");
        $calls{$clientid} = sub { $ua->put($url) };
    }

    print "Updating Customer IO records...\n";
    my $results = query_slowly(\%calls);

    for my $result (grep { $results->{$_}->res->code != 200 } sort keys %$results) {
        $log->warnf("Failed to update %s (%s)", $result, $results->{$result}->res->code);
    }
    my $success_count = scalar grep { $results->{$_}->res->code == 200 } keys %$results;
    print "$success_count/" . scalar(keys %$restore_data) . " Customer IO records restored\n";

} else {
    die "Usage: $0 --check <data.txt> or --delete <data.csv> or --restore <data.csv>";
}

# Loads CSV created by --check and returns hashref keyed by loginid
sub load_csv {

    my $file = shift;
    open my $fh, "<:encoding(utf8)", $file or die "$file: $!";
    $csv->column_names($csv->getline($fh));
    die 'CSV must contain loginid column' unless any { $_ eq 'loginid' } $csv->column_names();
    my %data;
    while (my $row = $csv->getline_hr($fh)) {
        $data{$row->{loginid}} = {map { $_ => $row->{$_} } grep { $_ ne 'loginid' } keys %$row};
    }
    close $fh;
    return \%data;
}

# Calls a list of sub refs adding pauses to not exceed rate limit
sub query_slowly {
    my $calls = shift;
    my %results;
    my $t_start = Time::HiRes::time();
    my $c       = 0;

    for my $item (keys %$calls) {
        $results{$item} = $calls->{$item}->();
        $c++;
        if ($c >= REQ_PER_SEC) {
            $c = 0;
            my $elapsed = Time::HiRes::time() - $t_start;
            Time::HiRes::sleep(1 - $elapsed) if ($elapsed < 1);
            $t_start = Time::HiRes::time();
        }
    }

    return \%results;
}

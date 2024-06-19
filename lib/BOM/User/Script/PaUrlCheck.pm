package BOM::User::Script::PaUrlCheck;

use strict;
use warnings;

use Future::AsyncAwait;
use Future::Utils qw( fmap_void fmap_scalar);
use IO::Async::Loop;
use Net::Async::HTTP;
use URI;
use BOM::Database::ClientDB;
use LandingCompany::Registry;
use Syntax::Keyword::Try;
use Text::Trim;
use Getopt::Long;
use Log::Any qw($log);
use constant CONCURRENT_REQUEST => 6;

my $log_level = 'info';
GetOptions("l=s" => \$log_level);
Log::Any::Adapter->import('DERIV', log_level => $log_level);
my $loop = IO::Async::Loop->new();
my $http = Net::Async::HTTP->new(
    max_connections_per_host => 1,
    timeout                  => 60,
    user_agent               => 'Mozilla/5.0 (Perl; Deriv.com; payment_agent_status;  sysadmin@deriv.com)',
    close_after_request      => 1

);
$loop->add($http);

=head1 Name

PaUrlCheck - check payment agents(pa) url is accessible 

=cut

=head2 new

Initialize db connections.

=cut

sub new {
    my $class = shift;
    my $self  = {};
    my @brokers =
        map { $_->{broker_codes}->@* } grep { $_->{allows_payment_agents} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
    $self->{brokers}{$_}{db} = BOM::Database::ClientDB->new({broker_code => uc $_})->db->dbic for @brokers;
    return bless $self, $class;
}

=head2 get_pa_urls

Fetches the list of authorized payment agents and their url.

=cut

sub get_pa_urls {
    my ($self, $clientdb) = @_;
    $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * from betonmarkets.get_payment_agents_urls()', {Slice => {}});
        });
}

=head2 update_url_status

set status of a url for particular loginid

=cut

sub update_url_status {
    my ($self, $clientdb, $loginid, $url, $is_accessible, $remark) = @_;
    $clientdb->run(
        fixup => sub {
            $_->do('SELECT * from betonmarkets.set_payment_agent_url_status(?, ?, ?, ?)', {Slice => {}}, $loginid, $url, $is_accessible, $remark);
        });
}

=head2 prepare_urls

prepare urls for http requests.

=cut

sub prepare_urls {
    my $self = shift;
    my $db   = shift;
    my $urls = shift;
    my @valid_urls;
    for ($urls->@*) {
        if ($_->{pa_url} !~ /^http/) {
            $log->infof('url is not valid because not starting with http', $_->{pa_url});
            $self->update_url_status($db, $_->{pa_loginid}, $_->{pa_url}, 0, 'not http url');
        } else {
            $_->{URI} = URI->new($_->{pa_url});
            push @valid_urls, $_;
        }
    }

    return @valid_urls;
}

=head2 response_code_extractor

Get the response code and check if it's not valid logs it.

=cut

sub response_code_extractor {
    my ($self, $url, $response) = @_;
    my $response_code = $response->code || '';
    unless ($response_code =~ m/^2\d+/) {
        $log->info(" $url->{URI} ", $response_code);
    }
    $url->{response_code} = $response_code;
    return $url;
}

=head2 retry_on_unrecognised

retry on new redirection location

=cut

async sub retry_on_unrecognised {
    my ($self, $url, $e) = @_;
    try {
        my $location = '';
        foreach (@$e) {
            if (ref($_) eq 'HTTP::Response' and $_->{_headers}) {
                $location = $_->{_headers}->{location};
            }
        }
        $url->{URI} = URI->new($url->{URI} . $location);
        $log->infof(
            '%s has Unrecognised Location error on new location: %s. The reason is because current version Net::Async::HTTP does not support relative path',
            $url->{URI}, $e
        );
        my $new_response = await $http->GET($url->{URI});
        return $self->response_code_extractor($url, $new_response);
    } catch ($e) {
        $log->infof('%s failed: %s', $url->{URI}, $e);
        $url->{remark} = $e;
        return $url;
    }
}

=head2 fmap_url_requests

send requests cuncurrently by using fmap_scalar

=cut

async sub fmap_url_requests {
    my $self          = shift;
    my @urls          = @_;
    my @url_responses = await fmap_scalar async sub {
        my $url = shift;
        try {
            my $response = await $http->GET($url->{URI});
            return $self->response_code_extractor($url, $response)
        } catch ($e) {
            return await $self->retry_on_unrecognised($url, $e) if $e =~ m/^Unrecognised Location/;
            $log->infof('%s failed: %s', $url->{URI}, $e);
            $url->{remark} = $e;
            return $url;
        }
        },
        foreach    => \@urls,
        concurrent => CONCURRENT_REQUEST;
    return @url_responses;

}

=head2 run

Execute db functions and http requests.

=cut

async sub run {
    my $self = shift;
    my @URLs;
    my $urls;
    $log->info("PaUrlCheck is running");
    for my $broker (keys $self->{brokers}->%*) {
        my $db = $self->{brokers}{$broker}{db};
        try {
            while ($urls = $self->get_pa_urls($db) and @$urls) {
                @URLs = $self->prepare_urls($db, $urls);
                my @url_responses = await $self->fmap_url_requests(@URLs);
                foreach my $url_response (@url_responses) {
                    my $remark        = $url_response->{response_code} ? $url_response->{response_code} : $url_response->{remark};
                    my $response_code = $url_response->{response_code} || '';
                    my $is_accessible = $response_code =~ m/^2\d+/ ? 1 : 0;
                    $self->update_url_status($db, $url_response->{pa_loginid}, $url_response->{pa_url}, $is_accessible, $remark);
                }
            }

        } catch ($e) {
            $log->errorf('Error processing broker %s: %s', $broker, $e);
        }
    }
    return 0;
}

1;

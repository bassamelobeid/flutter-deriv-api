package BOM::Platform::Event::Process;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use Locale::Country;
use Mojo::URL;
use Mojo::UserAgent;
use Try::Tiny;

use BOM::Config;
use BOM::User::Client;

=head1 NAME

BOM::Platform::Event::Process - Process events

=head1 SYNOPSIS

    BOM::Platform::Event::Process::process($event_to_be_processed)

=head1 DESCRIPTION

This class responsibility is to process events. It has action to method mapping.
Based on type of event its associated method is invoked.

=cut

use constant TIMEOUT => 5;

my $action_mapping = {
    register_details => \&_register_details,
    email_consent    => \&_email_consent,
};

=head1 METHODS

=head2 get_action_mappings

Returns available action mappings

=cut

sub get_action_mappings {
    return $action_mapping;
}

=head2 process

Process event passed by invoking corresponding method from action mapping

=head3 Required parameters

=over 4

=item * event_to_be_processed : registered event ({type => action, details => {}})

=back

=cut

sub process {
    # event is of form { type => action, details => {} }
    my $event_to_be_processed = shift;

    my $event_type = $event_to_be_processed->{type} // '';

    # don't process if type is not supported as of now
    return undef unless exists get_action_mappings()->{$event_type};

    # don't process if details are not present
    return undef unless exists $event_to_be_processed->{details};

    my $response = 0;
    try {
        $response = get_action_mappings()->{$event_type}->($event_to_be_processed->{details});
        stats_inc('generic_event.queue.processed.success');
    }
    catch {
        stats_inc('generic_event.queue.processed.failure');
    };

    return $response;
}

sub _register_details {
    my $data = shift;

    my $loginid = $data->{loginid};

    return undef unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid});

    return undef unless $client;

    my $details = {
        # mandatory
        email      => $client->email,
        created_at => Date::Utility->new($client->date_joined)->epoch,
        # optional
        company         => $client->landing_company->short,
        language        => $data->{language} // 'EN',
        first_name      => $client->first_name // '',
        last_name       => $client->last_name // '',
        affiliate_token => $client->myaffiliates_token // '',
        unsubscribed    => $data->{unsubscribe} ? 'true' : 'false',
        account_type    => $client->is_virtual ? 'virtual' : 'real',
        country_code => $client->residence // '',
        country => $client->residence ? Locale::Country::code2country($client->residence) : '',
        is_region_eu => $client->landing_company->short =~ /^(?:malta|iom)/ ? 1 : 0,
        # remove these before passing
        loginid => $loginid,
    };

    return _connect_and_update_customer_io($details);
}

sub _email_consent {
    my $data = shift;

    my $loginid = $data->{loginid};

    return undef unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid});

    return undef unless $client;

    my $details = {
        unsubscribed => $data->{email_consent} ? 'false' : 'true',
        loginid => $loginid,
    };

    return _connect_and_update_customer_io($details);
}

sub _connect_and_update_customer_io {
    my $details = shift;

    my $ua = Mojo::UserAgent->new->connect_timeout(TIMEOUT);

    my $config = BOM::Config::third_party()->{customerio};
    my $url    = Mojo::URL->new($config->{api_uri} . delete $details->{loginid})->userinfo($config->{api_site_id} . ':' . $config->{api_key});
    my $tx     = $ua->put($url => json => encode_json_utf8($details));

    if (my $err = $tx->error) {
        die 'Error - ' . $err->{code} . ' response: ' . $err->{message} if $err->{code};
        die 'Error - Connection error: ' . $err->{message};
    }

    return $tx->success ? 1 : 0;
}

1;

package BOM::Events::Actions::Customerio;

use strict;
use warnings;

use Locale::Country;
use Mojo::URL;
use Mojo::UserAgent;

use BOM::User::Client;
use BOM::Config;

use constant TIMEOUT => 5;

=head2 register_details

When a new user signed up for binary.com, register_details will send user information to https://customer.io/

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process

=back

=cut

sub register_details {
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

=head2 email_consent

When a user subscribes/unsubscribes to marketing's newsletter

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process

=back

=cut

sub email_consent {
    my $data    = shift;
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

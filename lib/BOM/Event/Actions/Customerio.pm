package BOM::Event::Actions::Customerio;

use strict;
use warnings;

use Locale::Country;
use Mojo::URL;
use Mojo::UserAgent;

use BOM::User::Client;
use BOM::Config;
use JSON::MaybeUTF8 qw(:v1);

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

    return _connect_and_update_customerio_record(_get_details_structure($client, $data));
}

=head2 email_consent

When a user subscribes/unsubscribes to marketing's newsletter

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process

=back

=cut

sub email_consent {
    my $data    = shift;
    my $loginid = delete $data->{loginid};

    return undef unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid});

    return undef unless $client;

    # trigger event for each client as customerio save it per loginid
    foreach my $client_obj ($client->user->clients()) {
        _connect_and_update_customerio_record(
            loginid => $client_obj->loginid,
            details => _get_details_structure(
                client          => $client_obj,
                customerio_data => $data
            ))
            and next
            if (exists $data->{email_consent} and $data->{email_consent});

        _connect_and_delete_customerio_record(loginid => $client_obj->loginid);
    }

    return 1;
}

sub _connect_and_delete_customerio_record {
    my (%args) = @_;

    my $url = _get_base_url($args{loginid});
    my $tx  = _get_user_agent()->delete($url);

    if (my $err = $tx->error) {
        die 'Error - ' . $err->{code} . ' response: ' . $err->{message} if $err->{code};
        die 'Error - Connection error: ' . $err->{message};
    }

    return $tx->success ? 1 : 0;
}

sub _connect_and_update_customerio_record {
    my (%args) = @_;

    my $url = _get_base_url($args{loginid});
    $url->query($args{details});
    my $tx = _get_user_agent()->put($url);

    if (my $err = $tx->error) {
        die 'Error - ' . $err->{code} . ' response: ' . $err->{message} if $err->{code};
        die 'Error - Connection error: ' . $err->{message};
    }

    return $tx->success ? 1 : 0;
}

sub _get_user_agent {
    return Mojo::UserAgent->new->connect_timeout(TIMEOUT);
}

sub _get_base_url {
    my $customerio_id = shift;

    my $config = BOM::Config::third_party()->{customerio};
    my $url    = Mojo::URL->new($config->{api_uri} . "/customers/$customerio_id");
    $url->userinfo($config->{site_id} . ':' . $config->{api_key});

    return $url;
}

sub _get_details_structure {
    my (%details) = @_;

    my $client = $details{client};
    my $data   = $details{customerio_data};

    return {
        # mandatory
        email      => $client->user->email,
        created_at => Date::Utility->new($client->date_joined)->epoch,

        # optional
        company         => $client->landing_company->short,
        language        => $data->{language} // 'EN',
        first_name      => $client->first_name // '',
        last_name       => $client->last_name // '',
        affiliate_token => $client->myaffiliates_token // '',
        unsubscribed    => $data->{email_consent} ? 'false' : 'true',
        account_type    => $client->is_virtual ? 'virtual' : 'real',
        country_code => $client->residence // '',
        country => $client->residence ? Locale::Country::code2country($client->residence) : '',
        is_region_eu => $client->is_region_eu,

        # remove these before passing
        loginid => $client->loginid,
    };
}

1;

package BOM::User::Utility;

use 5.014;
use strict;
use warnings;

use feature qw(state);

use Crypt::CBC;
use Crypt::NamedKeys;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use DateTime;
use Date::Utility;
use Encode;
use Encode::Detect::Detector;
use Syntax::Keyword::Try;
use Webservice::GAMSTOP;
use Email::Address::UseXS;
use Email::Stuffer;
use YAML::XS qw(LoadFile);
use WebService::SendBird;

use BOM::Platform::Context qw(request);
use BOM::Config::Runtime;

use Exporter qw(import);
our @EXPORT_OK = qw(parse_mt5_group);

use constant GAMSTOP_DURATION_IN_MONTHS => 6;

sub aes_keys {
    state $config = YAML::XS::LoadFile('/etc/rmg/aes_keys.yml');
    return $config;
}

sub encrypt_secret_answer {
    my $secret_answer = shift;
    return Crypt::NamedKeys->new(keyname => 'client_secret_answer')->encrypt_payload(data => $secret_answer);
}

sub decrypt_secret_answer {
    my $encoded_secret_answer = shift;

    return undef unless $encoded_secret_answer;

    my $secret_answer;
    try {
        if ($encoded_secret_answer =~ /^\w+\*.*\./) {    # new AES format
            $secret_answer = Crypt::NamedKeys->new(keyname => 'client_secret_answer')->decrypt_payload(value => $encoded_secret_answer);
        } elsif ($encoded_secret_answer =~ s/^::ecp::(\S+)$/$1/) {    # legacy blowfish
            my $cipher = Crypt::CBC->new({
                'key'    => aes_keys()->{client_secret_answer}->{1},
                'cipher' => 'Blowfish',
                'iv'     => aes_keys()->{client_secret_iv}->{1},
                'header' => 'randomiv',
            });

            $secret_answer = $cipher->decrypt_hex($encoded_secret_answer);
        } else {
            die "Invalid or outdated encrypted value.";
        }
    } catch {
        die "Not able to decode secret answer! $@";
    }

    return $secret_answer;
}

=head2 set_gamstop_self_exclusion

Marks a client as self-excluded if GAMSTOP tells us that we should.

Our exclusion here is hardcoded to 6 months - GAMSTOP only gives us a simple binary
"yes/no" for the exclusion query.

=cut

sub set_gamstop_self_exclusion {
    my $client = shift;

    return undef unless $client and $client->residence;

    # gamstop is only applicable for UK residence
    return undef unless request()->brand->countries_instance->countries_list->{$client->residence}->{gamstop_company};

    my $gamstop_config = BOM::Config::third_party()->{gamstop};

    my $lc                     = $client->landing_company->short;
    my $landing_company_config = $gamstop_config->{config}->{$lc};
    # don't request if we don't have gamstop key per landing company
    return undef unless $landing_company_config;

    my $gamstop_response;
    try {
        my $instance = Webservice::GAMSTOP->new(
            api_url => $gamstop_config->{api_uri},
            api_key => $landing_company_config->{api_key});

        $gamstop_response = $instance->get_exclusion_for(
            first_name    => $client->first_name,
            last_name     => $client->last_name,
            email         => $client->email,
            date_of_birth => $client->date_of_birth,
            postcode      => $client->postcode,
            mobile        => $client->phone,
        );

        stats_inc('GAMSTOP_RESPONSE', {tags => ['EXCLUSION:' . ($gamstop_response->get_exclusion() // 'NA'), "landing_company:$lc"]});
    } catch {
        stats_inc('GAMSTOP_CONNECT_FAILURE') if $@ =~ /^Error/;
    }

    return undef unless $gamstop_response;

    return undef if ($client->get_self_exclusion_until_date or not $gamstop_response->is_excluded());

    try {
        my $exclude_until = set_exclude_until_for($client, GAMSTOP_DURATION_IN_MONTHS);

        my $subject = 'Client ' . $client->loginid . ' was self-excluded via GAMSTOP until ' . $exclude_until;
        my $content = 'GAMSTOP self-exclusion will end on ' . $exclude_until;
        # send email to helpdesk.
        $client->add_note($subject, $content);
        my $brand = request()->brand();
        # also send email to compliance
        Email::Stuffer->from($brand->emails('compliance_alert'))->to($brand->emails('compliance_alert'))->subject($subject)->text_body($content)
            ->send_or_die;
    } catch {
        warn "An error occurred while setting client exclusion: $@";
    }

    return undef;
}

# set exclude_until to n-months from now and returns that in yyyy-mm-dd format
sub set_exclude_until_for {
    my ($client, $num_months) = @_;
    my $to_date = Date::Utility->new(DateTime->now()->add(months => $num_months))->date_yyyymmdd;
    $client->set_exclusion->exclude_until($to_date);
    $client->save();
    return $to_date;
}

=head2 login_details_identifier

Take an environment string from the "login_history" and return an identifier for this entry.

The identifier is a mix from the country, device (Android, Linux), and browser.

If one of these three pieces of information is missing it will be replaced with "unknown".

=cut

sub login_details_identifier {
    # This is a heavy module so we will only included it here
    require HTTP::BrowserDetect;

    my $enviroment_string = shift;
    return "" unless $enviroment_string;
    my ($country) = $enviroment_string =~ /IP_COUNTRY=(\w{1,2})/i;

    my ($user_agent) = $enviroment_string =~ /User_AGENT(.+(?=\sLANG))/i;
    $user_agent =~ s/User_AGENT=//i if $user_agent;

    my $browser_info = HTTP::BrowserDetect->new($user_agent);

    my $device  = $browser_info->device         || $browser_info->os_string || 'unknown';
    my $browser = $browser_info->browser_string || 'unknown';

    return ($country || 'unknown') . '::' . $device . '::' . $browser;
}

sub sendbird_api {
    my $config = BOM::Config::third_party()->{sendbird};

    return WebService::SendBird->new(
        api_token => $config->{api_token},
        app_id    => $config->{app_id},
    );
}

=head2 parse_mt5_group

Sample group: real\svg (old group name), real01\synthetic\svg_std_usd (new group name)

Returns

=over 4

=item * C<account_type> - real|demo

=item * C<server_type> - server id (E.g. 01, 02 ..)

=item * C<market_type> - financial|synthetic

=item * C<landing_company_short> - landing company short name (E.g. svg, malta ..)

=item * C<sub_account_type> - std|sf|stp

=item * C<currency> - group currency

=back

=cut

sub parse_mt5_group {
    my $group = shift;

    my ($account_type, $server_type, $market_type, $landing_company_short, $sub_account_type, $currency);

    # TODO (JB): remove old mt5 groups support when we have move all accounts over to the new groups
    # old mt5 groups support
    if ($group =~ m/^([a-z]+)\\([a-z]+)(?:_([a-z]+(?:_stp)?+))?(?:_([A-Z,a-z]+))?/) {
        $account_type          = $1;
        $landing_company_short = $2;
        my $subtype = $3;
        $currency         = lc($4 // 'usd');
        $server_type      = '01';                                                        # default to 01 for old group
        $market_type      = (not $subtype) ? 'synthetic' : 'financial';
        $sub_account_type = (defined $subtype and $subtype =~ /stp$/) ? 'stp' : 'std';
    } elsif ($group =~ /^(real|demo)(\d{2})\\(synthetic|financial)\\([a-z]+)_(.*)_(\w+)$/) {
        $account_type          = $1;
        $server_type           = $2;
        $market_type           = $3;
        $landing_company_short = $4;
        $sub_account_type      = $5;
        $currency              = $6;
    }

    return {
        account_type          => $account_type,
        server_type           => $server_type,
        market_type           => $market_type,
        landing_company_short => $landing_company_short,
        sub_account_type      => $sub_account_type,
        currency              => $currency,
    };
}

1;

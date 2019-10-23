#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeXS;
use BOM::Config::Runtime;
use BOM::Database::Helper::UserSpecificLimit;
use BOM::Database::ClientDB;
use BOM::User::Client;
use BOM::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Chronicle;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Limited clients');

Bar("Existing limited clients");

my $db         = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;
my $app_config = BOM::Config::Runtime->instance->app_config;
my $json       = JSON::MaybeXS->new(
    pretty    => 1,
    canonical => 1
);

my $custom_client_limits = $json->decode($app_config->get('quants.custom_client_profiles'));

my @users_limit = BOM::Database::Helper::UserSpecificLimit->new({db => $db})->select_user_specific_limit;

my @output = get_limited_client_list($custom_client_limits, @users_limit);

BOM::Backoffice::Request::template()->process(
    'backoffice/existing_user_limit.html.tt',
    {
        profit_table_url => request()->url_for('backoffice/f_profit_table.cgi?loginID='),
        url              => request()->url_for('backoffice/quant/client_limit.cgi'),
        output           => \@output,
    }) || die BOM::Backoffice::Request::template()->error;

my $r = request();

if ($r->params->{'deleteclientlimit'}) {
    my ($client_id, $market_type, $client_type, $limit_id) = split '-', $r->params->{'deleteclientlimit'};
    my @multiple = split(' ', $client_id);

    if ($limit_id eq 'N.A.') {

        BOM::Database::Helper::UserSpecificLimit->new({
                db             => $db,
                client_loginid => $multiple[0],    # first client_loginid will do
                client_type    => $client_type,
                market_type    => $market_type,
            })->delete_user_specific_limit;

    } else {

        delete $custom_client_limits->{$client_id}->{custom_limits}->{$limit_id};
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'quants.custom_client_profiles' => $json->encode($custom_client_limits)});

    }

}

sub get_limited_client_list {
    my ($custom_client_limits, @users_limit) = @_;

    my $limit_profile = BOM::Config::quants()->{risk_profile};
    my %known_profiles = map { $_ => 1 } keys %$limit_profile;

    my @client_output;
    foreach my $client_loginid (keys %$custom_client_limits) {
        my $binary_user_id = BOM::User::Client->new({loginid => $client_loginid})->binary_user_id;
        my %data           = %{$custom_client_limits->{$client_loginid}};
        my $reason         = $data{reason};
        my $limits         = $data{custom_limits};
        my $updated_by     = $data{updated_by};
        my $updated_on     = $data{updated_on};
        my @output;

        next if not $limits;

        foreach my $id (keys %$limits) {
            my %copy            = %{$limits->{$id}};
            my $comment         = delete $copy{name};
            my $profile         = delete $copy{risk_profile};
            my $limit_condition = join ",", map { $_ . "[$copy{$_}] " } grep { $copy{$_} } keys %copy;
            my $market_type     = $copy{market} ? ($copy{market} ne 'synthetic_index' ? 'financial' : 'non_financial') : 'N.A.';

            push @client_output, +{
                binary_user_id       => $binary_user_id,
                limit_id             => $id,
                client_id            => [$client_loginid],
                market_type          => $market_type,
                limit_type           => 'turnover and payout limit',
                comment              => $comment,
                updated_by           => $updated_by,
                updated_on           => $updated_on,
                limit_condition      => $limit_condition,
                payout_limit         => $profile ? $limit_profile->{$profile}{payout}{USD} : 'N.A.',
                turnover_limit       => $profile ? $limit_profile->{$profile}{turnover}{USD} : 'N.A.',
                client_type          => 'old',
                potential_loss_limit => 'N.A.',
                realized_loss_limit  => 'N.A.',
                expiry               => 'N.A',

            };
        }
    }

    my @new_user = grep { $_->{client_type} eq 'new' } @users_limit;
    my @old_user = grep { $_->{client_type} eq 'old' } @users_limit;

    foreach my $user (@old_user, @new_user) {
        my $updated_by = $user->{client_type} eq 'new' ? 'system' : 'staff';
        my $expiry = $user->{expiry} ? $user->{expiry} : 'N.A.';
        my $limit_type;
        if ($user->{client_type} eq 'new') {
            $limit_type = 'new_client_global_limit';

        } else {

            if ($user->{realized_loss} and $user->{potential_loss}) {
                $limit_type = 'realized_loss and potential loss limit';

            } else {
                $limit_type = $user->{realized_loss} ? 'realized_loss' : $user->{potential_loss} ? 'potential_loss' : 'N.A.';

            }

        }
        my $comment = $user->{client_type} eq 'new' ? "limiting new user on first week" : 'N.A.';

        push @client_output, +{
            binary_user_id       => $user->{binary_user_id},
            client_id            => $user->{client_loginid},
            limit_id             => 'N.A.',
            limit_type           => $limit_type,
            comment              => $comment,
            updated_by           => $updated_by,
            updated_on           => 'N.A.',
            limit_condition      => 'N.A',
            market_type          => $user->{market_type},
            payout_limit         => 'N.A.',
            turnover_limit       => 'N.A.',
            client_type          => $user->{client_type},
            potential_loss_limit => $user->{potential_loss} ? $user->{potential_loss} : 'N.A.',
            realized_loss_limit  => $user->{realized_loss} ? $user->{realized_loss} : 'N.A.',
            expiry               => $expiry,

        };
    }

    return @client_output;
}

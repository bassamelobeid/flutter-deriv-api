#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util 'looks_like_number';
use JSON::MaybeXS;
use Brands;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('EDIT PROMOTIONAL CODE DETAILS');

my %input = %{request()->params};

sub is_valid_promocode { return uc($_[0]->{promocode} // '') =~ /^\s*[A-Z0-9_\-\.]+\s*$/ ? 1 : 0 }

my $pc;
if (my $code = $input{promocode}) {
    $code =~ s/^\s+|\s+$//g;
    $pc = BOM::Database::AutoGenerated::Rose::PromoCode->new(
        broker => 'FOG',
        code   => uc($code));
    $pc->set_db('collector');
    $pc->load(speculative => 1);
}

Bar($pc ? "EDIT PROMOTIONAL CODE" : "ADD PROMOTIONAL CODE");

my @messages;
my $countries_instance = Brands->new(name => request()->brand)->countries_instance;

if ($input{save}) {
    @messages = _validation_errors(%input);
    if (@messages == 0) {
        eval {    ## no critic (RequireCheckingReturnValueOfEval)
            $pc->start_date($input{start_date})   if $input{start_date};
            $pc->expiry_date($input{expiry_date}) if $input{expiry_date};
            $pc->status($input{status});
            $pc->promo_code_type($input{promo_code_type});
            $pc->description($input{description});

            if ($input{country_type} eq 'not_offered') {
                my $countries_not_offered = ref $input{country} ? $input{country} : [$input{country}];
                my $rt_countries = $countries_instance->countries;
                my @countries_offered;
                foreach my $country (map { $rt_countries->code_from_country($_) } $rt_countries->all_country_names) {
                    push @countries_offered, $country unless (grep { $_ eq $country } @{$countries_not_offered});
                }
                $input{country} = join(',', @countries_offered);
            } else {
                $input{country} = join(',', @{$input{country}}) if ref $input{country};
            }

            for (qw/currency amount country min_turnover min_deposit/) {
                if ($input{$_}) {
                    $pc->{_json}{$_} = $input{$_};
                } else {
                    delete $pc->{_json}{$_};
                }
            }
            $pc->promo_code_config(JSON::MaybeXS->new->encode($pc->{_json}));
            $pc->save;
        };
        push @messages, ($@ || 'Save completed');
    }
}

$pc->{_json} ||= eval { JSON::from_json($pc->promo_code_config) } || {};

my $stash = {
    pc                 => $pc,
    pc_json            => $pc->{_json},
    messages           => \@messages,
    countries_instance => $countries_instance,
    is_valid_promocode => is_valid_promocode(\%input),
};
BOM::Backoffice::Request::template->process('backoffice/promocode_edit.html.tt', $stash)
    || die("in promocode_edit: " . BOM::Backoffice::Request::template->error());

code_exit_BO();

sub _validation_errors {
    my %input = @_;
    my @errors;
    for (qw/country description amount/) {
        $input{$_} || push @errors, "Field '$_' must be supplied";
    }
    # some of these are stored as json thus aren't checked by the orm or the database..
    for (qw/amount min_turnover min_deposit/) {
        my $val = $input{$_} || next;
        next if looks_like_number($val);
        push @errors, "Field '$_' value '$val' is not numeric";
    }
    # any more complex validation should go here..
    push @errors, "MINUMUM TURNOVER is only for FREE_BET promotions"
        if $input{min_turnover} && $input{promo_code_type} ne 'FREE_BET';
    push @errors, "MINUMUM DEPOSIT is only for GET_X_WHEN_DEPOSIT_Y promotions"
        if $input{min_deposit} && $input{promo_code_type} ne 'GET_X_WHEN_DEPOSIT_Y';
    push @errors, "Amount must be integer and in between 0 and 999" if ($input{amount} and $input{amount} !~ /^[1-9](?:[0-9]){0,2}$/);
    push @errors, "Promocode can only have: letters, underscore, minus and dot" unless is_valid_promocode(\%input);
    return @errors;
}

1;


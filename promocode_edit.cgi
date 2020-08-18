#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util 'looks_like_number';
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use Date::Utility;

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
my $countries_instance = request()->brand->countries_instance;

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
                my $rt_countries          = $countries_instance->countries;
                my @countries_offered;
                foreach my $country (map { $rt_countries->code_from_country($_) } $rt_countries->all_country_names) {
                    push @countries_offered, $country unless (grep { $_ eq $country } @{$countries_not_offered});
                }
                $input{country} = join(',', @countries_offered);
            } else {
                $input{country} = join(',', @{$input{country}}) if ref $input{country};
            }

            delete @input{qw/payment_processor turnover_type/} if $input{promo_code_type} eq 'FREE_BET';
            for (qw/currency amount country min_turnover turnover_type min_deposit payment_processor min_amount max_amount/) {
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

if ($pc) {
    $pc->{_json} ||= eval { JSON::from_json($pc->promo_code_config) } || {};
    $pc->{$_} = Date::Utility->new($pc->$_)->date_yyyymmdd for grep { $pc->$_ } qw/start_date expiry_date/;
}

my $stash = {
    pc                 => $pc,
    pc_json            => $pc->{_json},
    messages           => \@messages,
    countries_instance => $countries_instance,
    is_valid_promocode => is_valid_promocode(\%input),
};
BOM::Backoffice::Request::template()->process('backoffice/promocode_edit.html.tt', $stash)
    || die("in promocode_edit: " . BOM::Backoffice::Request::template()->error());

code_exit_BO();

sub _validation_errors {

    my %input = @_;
    my @errors;

    for (qw/country description amount/) {
        $input{$_} || push @errors, "Field '$_' must be supplied";
    }

    # some of these are stored as json thus aren't checked by the orm or the database..
    for (qw/amount min_turnover min_deposit min_amount max_amount/) {
        my $val = $input{$_} || next;
        next if looks_like_number($val);
        push @errors, "Field '$_' value '$val' is not numeric";
    }

    my ($start_date, $end_date) = @input{qw/start_date expiry_date/};

    # Date validation for start and expiry date
    try {

        $start_date = Date::Utility->new($start_date);
        $end_date   = Date::Utility->new($end_date);

        push @errors, "Expiry date must be set after Start date." if ($start_date && $end_date && $start_date->is_after($end_date));
    } catch {
        push @errors, "Start/Expiry date must be in the following format: YYYY-MM-DD";
    }

    # any more complex validation should go here..
    push @errors, "MINUMUM DEPOSIT is only for GET_X_WHEN_DEPOSIT_Y promotions"
        if $input{min_deposit} && $input{promo_code_type} ne 'GET_X_WHEN_DEPOSIT_Y';
    push @errors, "MINUMUM PAYOUT is only for GET_X_OF_DEPOSITS promotions"
        if $input{min_amount} && $input{promo_code_type} ne 'GET_X_OF_DEPOSITS';
    push @errors, "MAXIMUM PAYOUT is only for GET_X_OF_DEPOSITS promotions"
        if $input{max_amount} && $input{promo_code_type} ne 'GET_X_OF_DEPOSITS';
    if ($input{promo_code_type} eq 'GET_X_OF_DEPOSITS') {
        push @errors, "Amount must be a percentage between 1 and 100"
            if (looks_like_number($input{amount}) && ($input{amount} < 0.1 or $input{amount} > 100));
    } else {
        push @errors, "Amount must be a number between 0 and 999"
            if (looks_like_number($input{amount}) && ($input{amount} < 0 or $input{amount} > 999));
    }
    push @errors, "TURNOVER TYPE cannot be specified for FREE_BET promotions"
        if $input{turnover_type} && $input{promo_code_type} eq 'FREE_BET';
    push @errors, "TURNOVER TYPE must be specified for deposit promotions"
        if !$input{turnover_type} && $input{promo_code_type} ne 'FREE_BET';
    push @errors, "PAYMENT METHOD cannot be specified for FREE_BET promotions"
        if $input{payment_processor} && $input{promo_code_type} eq 'FREE_BET';
    push @errors, "PAYMENT METHOD must be specified for deposit promotions"
        if !$input{payment_processor} && $input{promo_code_type} ne 'FREE_BET';
    push @errors, "Promocode can only have: letters, underscore, minus and dot" unless is_valid_promocode(\%input);

    return @errors;
}

1;


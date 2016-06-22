package BOM::Platform::Client;

use strict;
use warnings;

use Try::Tiny;
use List::Util;
use Mail::Sender;
use DateTime;
use Date::Utility;
use Cache::RedisDB;
use List::Util qw(min);
use Format::Util::Numbers qw(roundnear);

use BOM::Platform::Context qw(request localize);
use BOM::Platform::Runtime;
use BOM::Platform::User;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Client;

use BOM::Database::AutoGenerated::Rose::Client::Manager;
use BOM::Database::AutoGenerated::Rose::SelfExclusion;
use BOM::Database::AutoGenerated::Rose::Users::BinaryUser;
use BOM::Database::Rose::DB::StringifyRules;
use BOM::Database::Rose::DB::Relationships;
use BOM::Platform::Client::PaymentAgent;
use BOM::Platform::Static::Config;
use BOM::Platform::Client::Payments;
use BOM::Platform::CurrencyConverter qw(in_USD);

use base 'BOM::Database::AutoGenerated::Rose::Client';

use Rose::DB::Object::Util qw(:all);
use Rose::Object::MakeMethods::Generic scalar => ['self_exclusion_cache'];

my $CLIENT_STATUS_TYPES = {
    age_verification          => 1,
    cashier_locked            => 1,
    disabled                  => 1,
    unwelcome                 => 1,
    withdrawal_locked         => 1,
    ukgc_funds_protection     => 1,    # UKGC License condition 4.2.1 for UK clients only
    tnc_approval              => 1,    # MGA License condition 2.7.1.10 for MLT clients only
    jp_knowledge_test_pending => 1,
    jp_knowledge_test_fail    => 1,
    jp_activation_pending     => 1,
};

sub client_status_types { return $CLIENT_STATUS_TYPES }

my $META = __PACKAGE__->meta;          # rose::db::object::manager meta rules. Knows our db structure

sub rnew { return shift->SUPER::new(@_) }

sub new {
    my $class = shift;
    my $args = shift || die 'BOM::Platform::Client->new called without args';

    my $loginid = $args->{loginid};
    die "no loginid" unless $loginid;

    my $operation = delete $args->{db_operation};

    my $self = $class->SUPER::new(%$args);

    $self->set_db($operation) if $operation;

    $self->load(speculative => 1) || return;    # must exist in db
    return $self;
}

sub get_instance {
    my $args = shift;
    return __PACKAGE__->new($args);
}

#              real db column                                    =>  legacy name
$META->column('address_city')->method_name('get_set' => 'city');
$META->column('address_line_1')->method_name('get_set' => 'address_1');
$META->column('address_line_2')->method_name('get_set' => 'address_2');
$META->column('address_postcode')->method_name('get_set' => 'postcode');
$META->column('address_state')->method_name('get_set' => 'state');
$META->column('client_password')->method_name('get_set' => 'password');

my $date_inflator_ymdhms = sub {
    my $self = shift;
    my $val = shift // return;
    return $val unless ref($val);
    return $val->isa('DateTime') ? ($val->ymd . ' ' . $val->hms) : $val;
};

my $date_inflator_ymd = sub {
    my $self = shift;
    my $val = shift // return;
    return $val unless ref($val);
    return $val->isa('DateTime') ? $val->ymd : $val;
};

for (qw/date_of_birth payment_agent_withdrawal_expiration_date/) {
    $META->column($_)->add_trigger(inflate => $date_inflator_ymd);
    $META->column($_)->add_trigger(deflate => $date_inflator_ymd);
}

for (qw/date_joined/) {
    $META->column($_)->add_trigger(inflate => $date_inflator_ymdhms);
    $META->column($_)->add_trigger(deflate => $date_inflator_ymdhms);
}

my %DEFAULT_VALUES = (
    cashier_setting_password => '',
    latest_environment       => '',
    restricted_ip_address    => '',
);

while (my ($column, $default) = each %DEFAULT_VALUES) {
    $META->column($column)->default($default);
}

# END OF METADATA -- do this after all 'meta' calls.
$META->initialize(replace_existing => 1);

sub save {
    my $self = shift;
    my $args = shift || {};
    # old code can set these numeric columns to ''.  should have been undef.
    for my $col (qw/custom_max_acbal custom_max_daily_turnover custom_max_payout/) {
        my $val = $self->$col // next;
        $self->$col(undef) if $val eq '';    # if we get here, it's defined.
    }

    $self->set_db('write');
    my $r = $self->SUPER::save(cascade => 1);    # Rose
    my $reset_statuses;
    for (values %{$self->{_clr_status}}) {       # see clr_status.
        $_->db($self->db);
        $_->delete;
        $reset_statuses++;
    }
    $self->client_status(undef) if $reset_statuses;
    return $r;
}

sub check_country_restricted {
    my $country_code = shift;
    return (    BOM::Platform::Runtime->instance->app_config->system->on_production
            and BOM::Platform::Runtime->instance->restricted_country($country_code));
}

sub register_and_return_new_client {
    my $class = shift;
    my $args  = shift;

    my $broker = $args->{broker_code} || die "can't register a new client without a broker_code";
    # assert broker before setting other properties so that correct write-handle will be cascaded!
    my $self = $class->rnew(broker => $broker);

    $self->set_db('write');
    while (my ($key, $val) = each %$args) {
        $self->$key($val);
    }

    # special cases.. force empty string if necessary in these not-nullable cols.  They oughta be nullable in the db!
    for (qw(citizen address_2 state postcode salutation)) {
        $self->$_ || $self->$_('');
    }

    $self->aml_risk_classification('low') unless $self->is_virtual;

    # resolve Gender from Salutation
    if ($self->salutation and not $self->gender) {
        my $gender = (uc $self->salutation eq 'MR') ? 'm' : 'f';
        $self->gender($gender);
    }
    $self->gender('m') unless $self->gender;

    my $sql = "SELECT nextval('sequences.loginid_sequence_$broker')";
    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my @seqnum = $sth->fetchrow_array();
    $self->loginid("$broker$seqnum[0]");
    $self->save;
    $self->load;

    return $self;
}

sub full_name {
    my $self = shift;
    return $self->salutation . ' ' . $self->first_name . ' ' . $self->last_name;
}

sub landing_company {
    my $self = shift;
    return BOM::Platform::Runtime->instance->broker_codes->get($self->broker)->landing_company;
}

sub set_promotion {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_promo_code(undef);    # empty Rose's read-only version..
    }
    # get the existing one or make a dummy one..
    if (my $obj = $self->client_promo_code) {
        return $obj;
    }
    my %args = (
        broker         => $self->broker,
        client_loginid => $self->loginid,
        status         => 'NOT_CLAIM',
        mobile         => '',
        apply_date     => Date::Utility->new->db_timestamp,
        db             => $self->db,
    );
    my $obj = BOM::Database::AutoGenerated::Rose::ClientPromoCode->new(%args);
    return $self->client_promo_code($obj);
}

# support legacy calls to these get/set shortcuts from Client to the promo_code record
sub promo_code {
    my $self = shift;
    return $self->set_promotion->promotion_code(@_) if @_;
    return ($self->client_promo_code || return)->promotion_code;
}

sub promo_code_status {
    my $self = shift;
    return $self->set_promotion->status(@_) if @_;
    return ($self->client_promo_code || return)->status;
}

sub promo_code_apply_date {
    my $self = shift;
    return $self->set_promotion->apply_date(@_) if @_;
    return ($self->client_promo_code || return)->apply_date;
}

sub promo_code_checked_in_myaffiliates {
    my $self = shift;
    return $self->set_promotion->checked_in_myaffiliates(@_) if @_;
    return ($self->client_promo_code || return)->checked_in_myaffiliates;
}

sub by_promo_code {
    my ($class, %args) = @_;
    my $broker = $args{broker_code} || die 'by_promo_code needs a broker_code';
    my $db = $class->rnew(broker => $broker)->db;
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_client(
        db           => $db,
        with_objects => ['client_promo_code'],
        query        => [%args],
        sort_by      => 't1.broker_code, t1.loginid'
    );
    # turn BPDPR::Client objects into (much smarter) Client objects
    return map { bless $_, $class } @$clients;
}

sub by_args {
    my ($class, %query) = @_;
    my $broker = $query{broker_code} || die 'by_args needs a broker_code';
    my %opts = (
        db      => $class->rnew(broker => $broker)->db,
        sort_by => 'broker_code, loginid'
    );
    if (my $limit = delete $query{limit}) {
        $opts{limit} = $limit;
    }
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_client(%opts, query => [%query]);
    # turn BPDPR::Client objects into (much smarter) Client objects
    return [map { bless $_, $class } @$clients];
}

sub get_objects_from_sql {
    my ($class, %args) = @_;
    my $broker = delete $args{broker_code} || die 'get_objects_from_sql needs a broker_code';
    $args{db} ||= $class->rnew(broker => $broker)->db;
    my $clients = BOM::Database::AutoGenerated::Rose::Client::Manager->get_objects_from_sql(%args);
    # turn BPDPR::Client objects into (much smarter) Client objects
    return [map { bless $_, $class } @$clients];
}

sub _change_vip_status {
    my $self = shift;
    my $new_status = (shift) ? 1 : 0;
    if ($new_status != $self->is_vip) {
        my $v = $new_status ? (Date::Utility->new->db_timestamp) : undef;
        $self->vip_since($v);
    }
    return;
}

sub is_vip {
    my $self = shift;
    $self->_change_vip_status($_[0]) if @_;    # note $_[0] might be zero or undef
    return $self->vip_since ? 1 : 0;
}

sub is_virtual { return BOM::Platform::Runtime->instance->broker_codes->get(shift->broker)->is_virtual }

sub has_funded { return (shift->first_funded_date ? 1 : 0) }

sub get_status {
    my ($self, $status_code) = @_;
    die "unkown status_code [$status_code]" unless $CLIENT_STATUS_TYPES->{$status_code};
    return List::Util::first {
        $_->status_code eq $status_code and not $self->{_clr_status}->{$status_code};
    }
    $self->client_status;
}

sub set_status {
    my ($self, $status_code, $staff_name, $reason) = @_;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_status(undef);    # throw out my read-only versions..
    }
    delete $self->{_clr_status}->{$status_code};
    my $obj = $self->get_status($status_code) || do {
        $self->add_client_status({status_code => $status_code});
        $self->get_status($status_code);
    };
    $obj->staff_name($staff_name || '');
    $obj->reason($reason         || '');
    $obj->db($self->db);
    return $obj;
}

sub clr_status {
    my ($self, $status_code) = @_;
    my $obj = $self->get_status($status_code) || return;
    $self->{_clr_status}->{$status_code} = $obj;
    return $obj;
    # The following is the only text-book way to remove one child from a child-collection in Rose..
    #my @other_statuses = grep { $_->status_code ne $status_code } $self->client_status;
    #$self->client_status(\@other_statuses);
    # but Rose clumsily implements this by removing all other childs and re-inserting them!
    # see https://groups.google.com/forum/#!topic/rose-db-object/410bHDrEbFU
    # We could enhance Rose with a del_{child} to fix this.
}

sub get_authentication {
    my $self            = shift;
    my $method          = shift;
    my $column          = shift;
    my $authentications = {map { $_->authentication_method_code => $_ } $self->client_authentication_method};
    my $obj             = $authentications->{$method} || return;
    return $column ? $obj->$column : $obj;
}

sub set_authentication {
    my $self   = shift;
    my $method = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
        $self->client_authentication_method(undef);    # throw out my read-only versions..
    }
    return $self->get_authentication($method) || do {
        $self->add_client_authentication_method({
            authentication_method_code => $method,
            status                     => 'pending'
        });
        $self->get_authentication($method);
        }
}

sub documents_expired {
    my $self  = shift;
    my $today = Date::Utility->today;
    my @docs  = $self->client_authentication_document or return;    # Rose
    for my $doc (@docs) {
        my $expires = $doc->expiration_date || return;
        return if Date::Utility->new($expires)->is_after($today);
    }
    return 1;
}

sub has_valid_documents {
    my $self  = shift;
    my $today = Date::Utility->today;
    for my $doc ($self->client_authentication_document) {
        my $expires = $doc->expiration_date || next;
        return 1 if Date::Utility->new($expires)->is_after($today);
    }
    return;
}

sub client_fully_authenticated {
    my $self        = shift;
    my $ID_DOCUMENT = $self->get_authentication('ID_DOCUMENT');
    my $NOTARIZED   = $self->get_authentication('ID_NOTARIZED');
    return (($ID_DOCUMENT and $ID_DOCUMENT->status eq 'pass') or ($NOTARIZED and $NOTARIZED->status eq 'pass'));
}

sub set_exclusion {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
    }
    # return the existing one..
    if (my $obj = $self->self_exclusion) {
        $obj->db($self->db);
        $self->self_exclusion_cache([$obj]);
        return $obj;
    }
    # or make a new one
    $self->self_exclusion(my $obj = BOM::Database::AutoGenerated::Rose::SelfExclusion->new());
    $self->self_exclusion_cache([$obj]);
    return $self->self_exclusion;
}

# make this relationship return its smarter version too
sub get_payment_agent {
    my $self = shift;
    my $obj  = $self->payment_agent || return;
    my $pa   = bless $obj, 'BOM::Platform::Client::PaymentAgent';
    return $pa;
}

# return a (new or existing) writeable BOM::Platform::Client::PaymentAgent
sub set_payment_agent {
    my $self = shift;
    unless ($self->get_db eq 'write') {
        $self->set_db('write');
    }
    # return the existing one..
    if (my $obj = $self->get_payment_agent) {
        $obj->db($self->db);
        return $obj;
    }
    # or make a new one
    # currency must be USD
    $self->set_default_account('USD') unless $self->default_account;
    die "Payment Agent currency can only be in USD" unless $self->default_account->currency_code eq 'USD';
    my %args = (
        client_loginid => $self->loginid,
        db             => $self->db
    );
    $self->payment_agent(BOM::Database::AutoGenerated::Rose::PaymentAgent->new(%args));
    return $self->get_payment_agent;
}

sub get_self_exclusion {
    my $self = shift;

    my $excl = $self->self_exclusion_cache;
    return $excl->[0] if $excl;

    $excl = $self->self_exclusion;
    $self->self_exclusion_cache([$excl]);
    return $excl;
}

sub get_limit_for_account_balance {
    my $self = shift;

    my @maxbalances = ();
    my $max_bal     = BOM::Platform::Static::Config::quants->{client_limits}->{max_balance};
    my $curr        = $self->currency;
    push @maxbalances, $self->is_virtual ? $max_bal->{virtual}->{$curr} : $max_bal->{real}->{$curr};

    if ($self->get_self_exclusion and $self->get_self_exclusion->max_balance) {
        push @maxbalances, $self->get_self_exclusion->max_balance;
    }

    if ($self->custom_max_acbal) {
        push @maxbalances, $self->custom_max_acbal;
    }

    return List::Util::min(@maxbalances);
}

sub get_limit_for_daily_turnover {
    my $self = shift;

    # turnover maxed at 500K of any currency.
    my @limits = (BOM::Platform::Static::Config::quants->{client_limits}->{maximum_daily_turnover}{$self->currency});
    if ($self->get_self_exclusion && $self->get_self_exclusion->max_turnover) {
        push @limits, $self->get_self_exclusion->max_turnover;
    }

    if (my $val = $self->custom_max_daily_turnover) {
        push @limits, $val;
    }

    return min(@limits);
}

sub get_limit_for_daily_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_losses) {
        return $excl->max_losses;
    }
    return;
}

sub get_limit_for_7day_turnover {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_7day_turnover) {
        return $excl->max_7day_turnover;
    }
    return;
}

sub get_limit_for_7day_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_7day_losses) {
        return $excl->max_7day_losses;
    }
    return;
}

sub get_limit_for_30day_turnover {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_30day_turnover) {
        return $excl->max_30day_turnover;
    }
    return;
}

sub get_limit_for_30day_losses {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    if ($excl && $excl->max_30day_losses) {
        return $excl->max_30day_losses;
    }
    return;
}

sub get_limit_for_open_positions {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    $excl = $excl->max_open_bets if $excl;

    return $excl && $excl < 60 ? $excl : 60;
}

# return undef or an exclusion date string
sub get_self_exclusion_until_dt {
    my $self = shift;

    my $excl = $self->get_self_exclusion;
    return unless $excl;

    my $exclude_until = $excl->exclude_until;
    my $timeout_until = $excl->timeout_until;

    # undef if expired
    undef $exclude_until
        if $exclude_until and Date::Utility->new($exclude_until)->is_before(Date::Utility->new);
    undef $timeout_until
        if $timeout_until and Date::Utility->new($timeout_until)->is_before(Date::Utility->new);

    return unless $exclude_until || $timeout_until;

    if ($exclude_until && $timeout_until) {
        my $exclude_until_dt = Date::Utility->new($exclude_until);
        my $timeout_until_dt = Date::Utility->new($timeout_until);

        return $exclude_until_dt->date if $exclude_until_dt->epoch < $timeout_until_dt->epoch;
        return $timeout_until_dt->datetime_yyyymmdd_hhmmss_TZ;
    }

    return Date::Utility->new($exclude_until)->date if $exclude_until;
    return Date::Utility->new($timeout_until)->datetime_yyyymmdd_hhmmss_TZ;
}

sub get_limit_for_payout {
    my $self = shift;

    my $val = $self->custom_max_payout;
    return $val if defined $val;

    my $max_payout = BOM::Platform::Static::Config::quants->{client_limits}->{max_payout_open_positions};

    return $max_payout->{$self->currency};
}

sub get_limit {
    my $self = shift;
    my $args = shift || die 'get_limit needs args';
    my $for  = $args->{for} || die 'get_limit needs a "for" arg';

    $for = 'get_limit_for_' . $for;
    return $self->$for;
}

sub currency {
    my $self = shift;

    # for Japan, both Virtual & Real a/c use JPY
    return 'JPY' if ($self->residence eq 'jp');
    return 'USD' if $self->is_virtual;

    if (my $account = $self->default_account) {
        return $account->currency_code;
    }

    return 'GBP' if $self->residence eq 'gb';
    return 'AUD' if $self->landing_company->short eq 'costarica' and $self->residence eq 'au';
    return $self->landing_company->legal_default_currency;
}

sub total_withdrawal_value {
    my $self = shift;

    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $self->loginid});
    my $withdrawal = $payment_mapper->get_total_withdrawal();
    return in_USD($withdrawal, $self->currency);
}

sub has_deposits {
    my $self           = shift;
    my $args           = shift;
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => $self->loginid});
    return $payment_mapper->get_payment_count_exclude_gateway($args);
}

sub is_first_deposit_pending {
    my $self = shift;
    return !$self->is_virtual && !$self->has_deposits;
}

sub first_funded_currency { return shift->_ffd->{first_funded_currency} }
sub first_funded_amount   { return shift->_ffd->{first_funded_amount} }
sub first_funded_date     { return shift->_ffd->{first_funded_date} }

sub _ffd {    # first_funded_details
    my $self           = shift;
    my $ffd            = {};
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $self->loginid});
    if (my $ff = $payment_mapper->first_funding) {
        $ffd->{first_funded_date}     = Date::Utility->new($ff->payment_time->epoch);
        $ffd->{first_funded_amount}   = sprintf '%.2f', $ff->amount;
        $ffd->{first_funded_currency} = $ff->account->currency_code;
    }
    return $ffd;
}

sub default_account {
    my $self     = shift;
    my @accounts = $self->account;    # Rose
    return $accounts[0] if @accounts == 1;
    $_->is_default && return $_ for @accounts;
    die "multiple accounts, no default\n" if @accounts;
    return;
}

sub set_default_account {
    my $self = shift;
    my $currency = shift || die 'no currency';
    $self->account(undef);            # throw out my read-only versions..
    $self->set_db('write') unless $self->get_db eq 'write';
    if (my $acc = $self->default_account) {
        my $orig_curr = $acc->currency_code;
        die "cannot deal in $currency; clients currency is $orig_curr" if $orig_curr ne $currency;
        return $acc;
    }
    my ($acc) = $self->add_account({
        currency_code => $currency,
        is_default    => 1
    });
    $self->save;
    return $acc;
}

sub open_bets {
    my $self    = shift;
    my $account = $self->default_account || return;
    my $fmbs    = $account->find_financial_market_bet(query => [is_sold => 0]);
    return @$fmbs;
}

=head1 CUSTOMER SERVICE RELATED FUNCTIONS

These are for interfacing with customer service facing applications (like email
queues or CRM applications).

=head2 add_note($subject, $content)

Adds a note for a customer record.  This is supposed to integrate with whatever
CS is doing, and returns 1 on success or 0 on failure.

Currently this is simply an emailer which sends the email to the desk.com
system.  Since we go through localhost, we die if there is an error.  This
might happen if somehow we are sending invalid SMTP commands or the like.

As the implementation changes the exceptions may change as well, but the basic
guarantee is that if there is a serious system error that prevents this from
working going forward with any input, it should die.

=cut

sub add_note {
    my ($self, $subject, $content) = @_;
    return if -e '/etc/rmg/travis';
    my $to = BOM::Platform::Static::Config::get_customer_support_email();
    local $\ = undef;
    my $from    = $to;
    my $replyto = $to;
    $replyto = $self->email if $self->email;

    return Mail::Sender->new()->MailMsg({
        on_errors => 'die',
        smtp      => 'localhost',                     # if this fails, sure, die, see above
        replyto   => $replyto,
        from      => $from,
        to        => $to,
        subject   => "SYSTEM MESSAGE: " . $subject,
        msg       => $content
    });
}

=pod

=head2 get_promocode_dependent_limit

get the limits based on promocode

=cut

sub get_promocode_dependent_limit {
    my ($client) = @_;

    my $payment_mapper = BOM::Database::DataMapper::Payment->new({
        'client_loginid' => $client->loginid,
        'currency_code'  => $client->currency,
    });

    my $total_free_gift_deposits            = $payment_mapper->get_total_free_gift_deposit();
    my $total_free_gift_rescind_withdrawals = $payment_mapper->get_total_free_gift_rescind_withdrawal();

    my $free_gift_deposits = $total_free_gift_deposits - $total_free_gift_rescind_withdrawals;

    my $frozen_free_gift = 0;
    my $turnover_limit   = 0;

    my $cpc = $client->client_promo_code;
    if ($cpc && $cpc->status !~ /^(CANCEL|REJECT)$/) {

        my $pc = $cpc->promotion;
        $pc->{_json} ||= try { JSON::from_json($pc->promo_code_config) } || {};

        if ($pc->promo_code_type eq 'FREE_BET') {

            my $min_turnover = $pc->{_json}{min_turnover};
            my $amount       = $pc->{_json}{amount};

            my $made_actual_deposit = $payment_mapper->get_total_deposit_of_account() - $amount;
            if ($made_actual_deposit) {
                $frozen_free_gift = $free_gift_deposits;
            } else {
                my $account_mapper = BOM::Database::DataMapper::Account->new({
                    'client_loginid' => $client->loginid,
                    'currency_code'  => $client->currency,
                });
                $frozen_free_gift = $account_mapper->get_balance();
            }

            $turnover_limit = 25 * $amount;

            # matched bets
            if (defined($min_turnover) and length($min_turnover) > 0) {
                $frozen_free_gift = 0;
            }

            my $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
                client_loginid => $client->loginid,
                currency_code  => $client->currency,
            });

            if (roundnear(0.01, $txn_data_mapper->get_turnover_of_account) >= $turnover_limit) {
                $frozen_free_gift = 0;
            }
        }
    }

    return {
        frozen_free_gift         => $frozen_free_gift,
        free_gift_turnover_limit => $turnover_limit,
    };
}

=pod

=head2 get_withdrawal_limits

get withdraw limits

=cut

sub get_withdrawal_limits {
    my $client = shift;

    my $withdrawal_limits = $client->get_promocode_dependent_limit();
    my $balance           = $client->default_account->balance;

    my $balance_minus_gift = List::Util::max(0, $balance - $withdrawal_limits->{'frozen_free_gift'});
    $withdrawal_limits->{'max_withdrawal'} = $balance_minus_gift;

    return $withdrawal_limits;
}

=head2 allow_paymentagent_withdrawal

to check client can withdrawal through payment agent. return 1 (allow) or undef (denied)

=cut

sub allow_paymentagent_withdrawal {
    my $client = shift;

    my $payment_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => $client->loginid});
    my $doughflow_count = $payment_mapper->get_client_payment_count_by({payment_gateway_code => 'doughflow'});

    return 1 if $doughflow_count == 0;

    my $expires_on = $client->payment_agent_withdrawal_expiration_date;
    return unless $expires_on;

    my $expiry_date = Date::Utility->new($expires_on);
    return 1 if $expiry_date->is_after(Date::Utility->new);

    return;
}

# Get my siblings, in loginid order but with reals up first.  Use the replica db for speed.
# Can be called as a class method, by passing email.
sub siblings {
    my $self  = shift;
    my $email = shift || $self->email;
    my $user  = BOM::Platform::User->new({email => $email}) || return;
    return $user->clients;
}

sub login_error {
    my $client = shift;

    if (grep { $client->loginid =~ /^$_/ } @{BOM::Platform::Runtime->instance->app_config->system->suspend->logins}) {
        return localize('Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.');
    } elsif ($client->get_status('disabled')) {
        return localize('This account is unavailable. For any questions please contact Customer Support.');
    } elsif (my $self_exclusion_dt = $client->get_self_exclusion_until_dt) {
        return localize('Sorry, you have excluded yourself until [_1].', $self_exclusion_dt);
    }
    return;
}

1;


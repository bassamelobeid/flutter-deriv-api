package BOM::Backoffice::Script::ExtraTranslations;

use Moose;
with 'App::Base::Script';

use Try::Tiny;
use IO::File;
use File::ShareDir;
use Module::Load::Conditional qw( can_load );
use Locale::Maketext::Extract;
use YAML::XS qw(LoadFile);
use LandingCompany::Offerings;

use Finance::Contract::Category;
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;

use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::MarketData::Types;
use BOM::Product::Static;
use Finance::Contract::Longcode;
use BOM::Platform::Runtime;

has file_container => (
    is         => 'ro',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

sub _build_file_container {
    my $self        = shift;
    my $current_pot = IO::File->new($self->pot_filename, 'r');
    my @content     = <$current_pot>;
    return [map { chomp; $_ } @content];
}

has pot_filename => (
    is      => 'rw',
    isa     => 'Str',
    default => '',
);

has pot_append_fh => (
    is         => 'ro',
    isa        => 'IO::File',
    lazy_build => 1,
);

sub _build_pot_append_fh {
    my $self = shift;
    return IO::File->new($self->pot_filename, 'a');
}

sub documentation {
    return "Populates our pot file with translations that are not directly picked up by xgettext.pl. Run it with the location to pot file.";
}

sub cli_template {
    return "$0 [options] messages.po";
}

sub script_run {
    my ($self, $pot_filename) = @_;

    die "Unable to open $pot_filename for writing" if (not -w $pot_filename);

    $self->pot_filename($pot_filename);
    my $fh = $self->pot_append_fh;

    print $fh "\n# Start of extra_translations\n";
    $self->add_underlyings;
    $self->add_contract_categories;
    $self->add_contract_types;
    $self->add_japan_settings;
    $self->add_longcodes;
    $self->add_generic_texts;
    $self->add_error_messages;

    return 0;
}

sub add_japan_settings {
    my $self = shift;

    # After client settings update, system email client & CS for changes. These translate old & new settings in email
    # use in BOM::RPC::v3::Japan::NewAccount::set_jp_settings

    my @texts = (
        # Occupation
        '{JAPAN ONLY}Office worker',
        '{JAPAN ONLY}Director',
        '{JAPAN ONLY}Public worker',
        '{JAPAN ONLY}Self-employed',
        '{JAPAN ONLY}Housewife / Househusband',
        '{JAPAN ONLY}Contract / Temporary / Part Time',
        '{JAPAN ONLY}Student',
        '{JAPAN ONLY}Unemployed',
        '{JAPAN ONLY}Others',

        # Income
        '{JAPAN ONLY}Less than 1 million JPY',
        '{JAPAN ONLY}1-3 million JPY',
        '{JAPAN ONLY}3-5 million JPY',
        '{JAPAN ONLY}5-10 million JPY',
        '{JAPAN ONLY}10-30 million JPY',
        '{JAPAN ONLY}30-50 million JPY',
        '{JAPAN ONLY}50-100 million JPY',
        '{JAPAN ONLY}Over 100 million JPY',

        # Trading Experience
        '{JAPAN ONLY}No experience',
        '{JAPAN ONLY}Less than 6 months',
        '{JAPAN ONLY}6 months to 1 year',
        '{JAPAN ONLY}1-3 years',
        '{JAPAN ONLY}3-5 years',
        '{JAPAN ONLY}Over 5 years',

        # purpose of trading
        '{JAPAN ONLY}Targeting short-term profits',
        '{JAPAN ONLY}Targeting medium-term / long-term profits',
        '{JAPAN ONLY}Both the above',
        '{JAPAN ONLY}Hedging',

        # asset hedge
        '{JAPAN ONLY}Foreign currency deposit',
        '{JAPAN ONLY}Margin FX',
        '{JAPAN ONLY}Other'
    );

    my $fh = $self->pot_append_fh;
    foreach my $txt (@texts) {
        my $msgid = $self->msg_id($txt);
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_underlyings {
    my $self = shift;

    my @underlyings = map { create_underlying($_) } create_underlying_db()->get_symbols_for(
        market           => [Finance::Asset::Market::Registry->all_market_names],
        exclude_disabled => 1
    );

    my $fh = $self->pot_append_fh;

    foreach my $underlying (@underlyings) {
        next unless $underlying->{display_name};
        my $msgid = $self->msg_id($underlying->{display_name});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    $self->add_markets;
    $self->add_submarkets;

    return 0;
}

sub add_contract_types {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    my $contract_type_config = Finance::Contract::Category::get_all_contract_types();

    foreach my $contract_type (keys %{$contract_type_config}) {
        next if ($contract_type eq 'INVALID');

        if (my $display_name = $contract_type_config->{$contract_type}->{display_name}) {
            my $msgid = $self->msg_id($display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub add_contract_categories {
    my $self = shift;

    my $fh = $self->pot_append_fh;
    my @all_categories = map { Finance::Contract::Category->new($_) }
        LandingCompany::Offerings->get('costarica', BOM::Platform::Runtime->instance->get_offerings_config)->values_for_key('contract_category');
    foreach my $contract_category (@all_categories) {
        if ($contract_category->display_name) {
            my $msgid = $self->msg_id($contract_category->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
        if ($contract_category->explanation) {
            my $msgid = $self->msg_id($contract_category->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub add_markets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    foreach my $market (Finance::Asset::Market::Registry->all) {
        if ($market->display_name) {
            my $msgid = $self->msg_id($market->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }

        if ($market->explanation) {
            my $msgid = $self->msg_id($market->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }
    return;
}

sub add_submarkets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    foreach my $submarket (Finance::Asset::SubMarket::Registry->all) {
        if ($submarket->display_name) {
            my $msgid = $self->msg_id($submarket->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }

        if ($submarket->explanation) {
            my $msgid = $self->msg_id($submarket->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub add_longcodes {
    my $self = shift;

    my $fh        = $self->pot_append_fh;
    my $longcodes = Finance::Contract::Longcode::get_longcodes();

    foreach my $longcode (keys %$longcodes) {
        my $msgid = $self->msg_id($longcodes->{$longcode});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_generic_texts {
    my $self = shift;

    my $fh       = $self->pot_append_fh;
    my $messages = BOM::Product::Static::get_generic_mapping();

    foreach my $key (keys %$messages) {
        my $msgid = $self->msg_id($messages->{$key});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub add_error_messages {
    my $self = shift;

    my $fh            = $self->pot_append_fh;
    my $error_mapping = BOM::Product::Static::get_error_mapping();

    foreach my $err (keys %$error_mapping) {
        my $msgid = $self->msg_id($error_mapping->{$err});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    return;
}

sub is_id_unique {
    my ($self, $key) = @_;

    my $flag = 0;
    if (not exists $self->_extant_msg_ids->{$key}) {
        $flag = 1;
        $self->_extant_msg_ids->{$key} = undef;
    }

    return $flag;
}

sub msg_id {
    my $self   = shift;
    my $string = shift;
    return 'msgid "' . Locale::Maketext::Extract::_maketext_to_gettext($string) . '"';
}

has _extant_msg_ids => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__extant_msg_ids {
    my $self = shift;

    return {map { $_ => undef } grep { /^msgid / } (@{$self->file_container})};
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

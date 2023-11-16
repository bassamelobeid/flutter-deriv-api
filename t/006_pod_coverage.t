use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Database::AuthDB'                                    => 1,
    'BOM::Database::QuantsConfig'                              => 8,
    'BOM::Database::ClientDB'                                  => 5,
    'BOM::Database::UserDB'                                    => 1,
    'BOM::Database::Rose::DB'                                  => 4,
    'BOM::Database::Script::GenerateRoseClasses'               => 5,
    'BOM::Database::Script::CheckDataChecksums'                => 1,
    'BOM::Database::Script::DBMigration'                       => 6,
    'BOM::Database::Script::IccubeUpdateUnderlying'            => 1,
    'BOM::Database::Model::OAuth'                              => 29,
    'BOM::Database::Model::Transaction'                        => 2,
    'BOM::Database::Model::UserConnect'                        => 5,
    'BOM::Database::Model::Base'                               => 6,
    'BOM::Database::Model::Account'                            => 5,
    'BOM::Database::Model::FinancialMarketBetOpen'             => 5,
    'BOM::Database::Model::AccessToken'                        => 8,
    'BOM::Database::Model::FinancialMarketBet'                 => 6,
    'BOM::Database::Model::HandoffToken'                       => 4,
    'BOM::Database::Model::ExchangeRate'                       => 2,
    'BOM::Database::Model::Constants'                          => 0,
    'BOM::Database::Helper::UserSpecificLimit'                 => 5,
    'BOM::Database::Helper::RejectedTrade'                     => 1,
    'BOM::Database::Helper::QuestionsAnswered'                 => 1,
    'BOM::Database::Helper::FinancialMarketBet'                => 7,
    'BOM::Database::DataMapper::Transaction'                   => 5,
    'BOM::Database::DataMapper::Base'                          => 2,
    'BOM::Database::DataMapper::CollectorReporting'            => 5,
    'BOM::Database::DataMapper::Payment'                       => 1,
    'BOM::Database::DataMapper::AccountBase'                   => 1,
    'BOM::Database::DataMapper::FinancialMarketBet'            => 5,
    'BOM::Database::DataMapper::Copier'                        => 1,
    'BOM::Database::Rose::DB::Cache'                           => 1,
    'BOM::Database::Rose::DB::Relationships'                   => 2,
    'BOM::Database::Model::FinancialMarketBet::HighLowTick'    => 5,
    'BOM::Database::Model::FinancialMarketBet::CallputSpread'  => 5,
    'BOM::Database::Model::FinancialMarketBet::Multiplier'     => 5,
    'BOM::Database::Model::FinancialMarketBet::Accumulator'    => 5,
    'BOM::Database::Model::FinancialMarketBet::LegacyBet'      => 5,
    'BOM::Database::Model::FinancialMarketBet::Runs'           => 5,
    'BOM::Database::Model::FinancialMarketBet::DigitBet'       => 5,
    'BOM::Database::Model::FinancialMarketBet::HigherLowerBet' => 5,
    'BOM::Database::Model::FinancialMarketBet::TouchBet'       => 5,
    'BOM::Database::Model::FinancialMarketBet::LookbackOption' => 5,
    'BOM::Database::Model::FinancialMarketBet::ResetBet'       => 5,
    'BOM::Database::Model::FinancialMarketBet::RangeBet'       => 5,
    'BOM::Database::Model::FinancialMarketBet::SpreadBet'      => 5,
    'BOM::Database::Model::FinancialMarketBet::Vanilla'        => 5,
    'BOM::Database::Model::FinancialMarketBet::Turbos'         => 5,
    'BOM::Database::Model::DataCollection::QuantsBetVariables' => 2,
    'BOM::Database::DataMapper::Payment::DoughFlow'            => 1,
    'BOM::Database::Rose::DB::Object::AutoBase1'               => 6,
};

my $ignored_packages = [
    'BOM::Database::AutoGenerated::Rose::Users::BinaryUser::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::LoginHistory::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::LastLogin::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::BinaryUserConnect::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::Loginid::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::FailedLogin::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::EmailPasswordMap::Manager',
    'BOM::Database::AutoGenerated::Rose::Auth::Developer::Manager',
    'BOM::Database::AutoGenerated::Rose::Auth::Client::Manager',
    'BOM::Database::AutoGenerated::Rose::Auth::AccessToken::Manager',
    'BOM::Database::AutoGenerated::Rose::CustomPgErrorCode::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentFilter::Manager',
    'BOM::Database::AutoGenerated::Rose::Account::Manager',
    'BOM::Database::AutoGenerated::Rose::RejectedTrade::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentAgent::Manager',
    'BOM::Database::AutoGenerated::Rose::LimitOrder::Manager',
    'BOM::Database::AutoGenerated::Rose::Payment::Manager',
    'BOM::Database::AutoGenerated::Rose::RunBet::Manager',
    'BOM::Database::AutoGenerated::Rose::BrokerCode::Manager',
    'BOM::Database::AutoGenerated::Rose::SanctionsCheck::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure::Manager',
    'BOM::Database::AutoGenerated::Rose::AccountTransfer::Manager',
    'BOM::Database::AutoGenerated::Rose::QuantsBetVariable::Manager',
    'BOM::Database::AutoGenerated::Rose::HigherLowerBet::Manager',
    'BOM::Database::AutoGenerated::Rose::BetDictionary::Manager',
    'BOM::Database::AutoGenerated::Rose::Highlowtick::Manager',
    'BOM::Database::AutoGenerated::Rose::AffiliateReward::Manager',
    'BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager',
    'BOM::Database::AutoGenerated::Rose::Doughflow::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientStatusCode::Manager',
    'BOM::Database::AutoGenerated::Rose::LegacyBet::Manager',
    'BOM::Database::AutoGenerated::Rose::AppMarkupPayableAccount::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientPromoCode::Manager',
    'BOM::Database::AutoGenerated::Rose::Client::Manager',
    'BOM::Database::AutoGenerated::Rose::LoginHistory::Manager',
    'BOM::Database::AutoGenerated::Rose::CurrencyConversionTransfer::Manager',
    'BOM::Database::AutoGenerated::Rose::BankWire::Manager',
    'BOM::Database::AutoGenerated::Rose::First::Manager',
    'BOM::Database::AutoGenerated::Rose::WesternUnion::Manager',
    'BOM::Database::AutoGenerated::Rose::BetClassWithoutPayoutPrice::Manager',
    'BOM::Database::AutoGenerated::Rose::CoinauctionBet::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientLock::Manager',
    'BOM::Database::AutoGenerated::Rose::EndOfDayBalance::Manager',
    'BOM::Database::AutoGenerated::Rose::Transaction::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentAgentTransfer::Manager',
    'BOM::Database::AutoGenerated::Rose::Users::LastLogin',
    'BOM::Database::AutoGenerated::Rose::Users::FailedLogin',
    'BOM::Database::AutoGenerated::Rose::Users::Loginid',
    'BOM::Database::AutoGenerated::Rose::Users::EmailPasswordMap',
    'BOM::Database::AutoGenerated::Rose::Users::LoginHistory',
    'BOM::Database::AutoGenerated::Rose::Users::BinaryUserConnect',
    'BOM::Database::AutoGenerated::Rose::Users::BinaryUser',
    'BOM::Database::AutoGenerated::Rose::ProductionServer::Manager',
    'BOM::Database::AutoGenerated::Rose::UnderlyingSymbolCurrencyMapper::Manager',
    'BOM::Database::AutoGenerated::Rose::SelfExclusion::Manager',
    'BOM::Database::AutoGenerated::Rose::Copier::Manager',
    'BOM::Database::AutoGenerated::Rose::EpgRequest::Manager',
    'BOM::Database::AutoGenerated::Rose::Runs::Manager',
    'BOM::Database::AutoGenerated::Rose::DigitBet::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentGateway::Manager',
    'BOM::Database::AutoGenerated::Rose::ResetBet::Manager',
    'BOM::Database::AutoGenerated::Rose::MyaffiliatesCommission::Manager',
    'BOM::Database::AutoGenerated::Rose::EndOfDayOpenPosition::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentType::Manager',
    'BOM::Database::AutoGenerated::Rose::RealtimeBookArchive::Manager',
    'BOM::Database::AutoGenerated::Rose::FinancialAssessment::Manager',
    'BOM::Database::AutoGenerated::Rose::LookbackOption::Manager',
    'BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail::Manager',
    'BOM::Database::AutoGenerated::Rose::LegacyPayment::Manager',
    'BOM::Database::AutoGenerated::Rose::SpreadBet::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientStatus::Manager',
    'BOM::Database::AutoGenerated::Rose::PaymentFee::Manager',
    'BOM::Database::AutoGenerated::Rose::HistoricalMarkedToMarket::Manager',
    'BOM::Database::AutoGenerated::Rose::ErcCurrencyConfig::Manager',
    'BOM::Database::AutoGenerated::Rose::Epg::Manager',
    'BOM::Database::AutoGenerated::Rose::CurrencyConfig::Manager',
    'BOM::Database::AutoGenerated::Rose::ExchangeRate::Manager',
    'BOM::Database::AutoGenerated::Rose::RangeBet::Manager',
    'BOM::Database::AutoGenerated::Rose::PromoCode::Manager',
    'BOM::Database::AutoGenerated::Rose::FreeGift::Manager',
    'BOM::Database::AutoGenerated::Rose::Auth::Developer',
    'BOM::Database::AutoGenerated::Rose::Auth::AccessToken',
    'BOM::Database::AutoGenerated::Rose::Auth::Client',
    'BOM::Database::AutoGenerated::Rose::RealtimeBook::Manager',
    'BOM::Database::AutoGenerated::Rose::AppMarkupPayable::Manager',
    'BOM::Database::AutoGenerated::Rose::Multiplier::Manager',
    'BOM::Database::AutoGenerated::Rose::Accumulator::Manager',
    'BOM::Database::AutoGenerated::Rose::CallputSpread::Manager',
    'BOM::Database::AutoGenerated::Rose::Vanilla::Manager',
    'BOM::Database::AutoGenerated::Rose::Turbos::Manager',
    'BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager',
    'BOM::Database::AutoGenerated::Rose::DailyAggregate::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod::Manager',
    'BOM::Database::AutoGenerated::Rose::TouchBet::Manager',
    'BOM::Database::AutoGenerated::Rose::HandoffToken::Manager',
    'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument::Manager',
    'BOM::Database::AutoGenerated::Rose::ExpiredUnsold::Manager',
    'BOM::Database::AutoGenerated::Rose::ContractGroup::Manager',
    'BOM::Database::AutoGenerated::Rose::Market::Manager',
    'BOM::Database::AutoGenerated::Rose::QuantsBetVariable',
    'BOM::Database::AutoGenerated::Rose::ContractGroup',
    'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument',
    'BOM::Database::AutoGenerated::Rose::ProductionServer',
    'BOM::Database::AutoGenerated::Rose::ErcCurrencyConfig',
    'BOM::Database::AutoGenerated::Rose::CurrencyConversionTransfer',
    'BOM::Database::AutoGenerated::Rose::PaymentFilter',
    'BOM::Database::AutoGenerated::Rose::Transaction',
    'BOM::Database::AutoGenerated::Rose::RejectedTrade',
    'BOM::Database::AutoGenerated::Rose::Market',
    'BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure',
    'BOM::Database::AutoGenerated::Rose::PaymentAgentTransfer',
    'BOM::Database::AutoGenerated::Rose::BetDictionary',
    'BOM::Database::AutoGenerated::Rose::CustomPgErrorCode',
    'BOM::Database::AutoGenerated::Rose::WesternUnion',
    'BOM::Database::AutoGenerated::Rose::CoinauctionBet',
    'BOM::Database::AutoGenerated::Rose::CallputSpread',
    'BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail',
    'BOM::Database::AutoGenerated::Rose::EpgRequest',
    'BOM::Database::AutoGenerated::Rose::AffiliateReward',
    'BOM::Database::AutoGenerated::Rose::EndOfDayBalance',
    'BOM::Database::AutoGenerated::Rose::UnderlyingSymbolCurrencyMapper',
    'BOM::Database::AutoGenerated::Rose::BankWire',
    'BOM::Database::AutoGenerated::Rose::BrokerCode',
    'BOM::Database::AutoGenerated::Rose::Multiplier',
    'BOM::Database::AutoGenerated::Rose::Accumulator',
    'BOM::Database::AutoGenerated::Rose::Vanilla',
    'BOM::Database::AutoGenerated::Rose::Turbos',
    'BOM::Database::AutoGenerated::Rose::Account',
    'BOM::Database::AutoGenerated::Rose::RealtimeBookArchive',
    'BOM::Database::AutoGenerated::Rose::Doughflow',
    'BOM::Database::AutoGenerated::Rose::SanctionsCheck',
    'BOM::Database::AutoGenerated::Rose::Highlowtick',
    'BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen',
    'BOM::Database::AutoGenerated::Rose::LegacyBet',
    'BOM::Database::AutoGenerated::Rose::LegacyPayment',
    'BOM::Database::AutoGenerated::Rose::AppMarkupPayable',
    'BOM::Database::AutoGenerated::Rose::Client',
    'BOM::Database::AutoGenerated::Rose::RunBet',
    'BOM::Database::AutoGenerated::Rose::Payment',
    'BOM::Database::AutoGenerated::Rose::PaymentType',
    'BOM::Database::AutoGenerated::Rose::ExpiredUnsold',
    'BOM::Database::AutoGenerated::Rose::RealtimeBook',
    'BOM::Database::AutoGenerated::Rose::ClientPromoCode',
    'BOM::Database::AutoGenerated::Rose::FreeGift',
    'BOM::Database::AutoGenerated::Rose::MyaffiliatesCommission',
    'BOM::Database::AutoGenerated::Rose::Runs',
    'BOM::Database::AutoGenerated::Rose::PromoCode',
    'BOM::Database::AutoGenerated::Rose::PaymentGateway',
    'BOM::Database::AutoGenerated::Rose::DigitBet',
    'BOM::Database::AutoGenerated::Rose::FinancialMarketBet',
    'BOM::Database::AutoGenerated::Rose::ClientStatusCode',
    'BOM::Database::AutoGenerated::Rose::AccountTransfer',
    'BOM::Database::AutoGenerated::Rose::EndOfDayOpenPosition',
    'BOM::Database::AutoGenerated::Rose::ClientLock',
    'BOM::Database::AutoGenerated::Rose::HigherLowerBet',
    'BOM::Database::AutoGenerated::Rose::PaymentFee',
    'BOM::Database::AutoGenerated::Rose::TouchBet',
    'BOM::Database::AutoGenerated::Rose::HistoricalMarkedToMarket',
    'BOM::Database::AutoGenerated::Rose::LookbackOption',
    'BOM::Database::AutoGenerated::Rose::PaymentAgent',
    'BOM::Database::AutoGenerated::Rose::CurrencyConfig',
    'BOM::Database::AutoGenerated::Rose::ClientStatus',
    'BOM::Database::AutoGenerated::Rose::ResetBet',
    'BOM::Database::AutoGenerated::Rose::Copier',
    'BOM::Database::AutoGenerated::Rose::RangeBet',
    'BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod',
    'BOM::Database::AutoGenerated::Rose::AppMarkupPayableAccount',
    'BOM::Database::AutoGenerated::Rose::First',
    'BOM::Database::AutoGenerated::Rose::BetClassWithoutPayoutPrice',
    'BOM::Database::AutoGenerated::Rose::LimitOrder',
    'BOM::Database::AutoGenerated::Rose::SpreadBet',
    'BOM::Database::AutoGenerated::Rose::Epg',
    'BOM::Database::AutoGenerated::Rose::HandoffToken',
    'BOM::Database::AutoGenerated::Rose::FinancialAssessment',
    'BOM::Database::AutoGenerated::Rose::DailyAggregate',
    'BOM::Database::AutoGenerated::Rose::LoginHistory',
    'BOM::Database::AutoGenerated::Rose::SelfExclusion',
    'BOM::Database::AutoGenerated::Rose::ExchangeRate',
];

Test::Pod::CoverageChange::pod_coverage_syntax_ok(
    allowed_naked_packages => $allowed_naked_packages,
    ignored_packages       => $ignored_packages
);

done_testing();

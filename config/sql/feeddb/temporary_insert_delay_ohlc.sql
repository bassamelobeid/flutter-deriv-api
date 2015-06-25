SET client_min_messages TO warning;

DROP TRIGGER tick_insert_trigger ON feed.tick;
DROP TRIGGER ohlc_minutely_insert_trigger ON feed.ohlc_minutely;
DROP TRIGGER ohlc_hourly_insert_trigger ON feed.ohlc_hourly;
DROP TRIGGER ohlc_daily_insert_trigger ON feed.ohlc_daily;

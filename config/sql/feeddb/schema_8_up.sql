BEGIN;

CREATE TABLE feed.realtime_ohlc (
    granuality BIGINT NOT NULL,
    underlying VARCHAR(128) NOT NULL,
    ts TIMESTAMP NOT NULL,
    open DOUBLE PRECISION NOT NULL,
    high DOUBLE PRECISION NOT NULL,
    low DOUBLE PRECISION NOT NULL,
    close DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (granuality,underlying)
);


CREATE OR REPLACE FUNCTION update_realtime_ohlc(fgranuality BIGINT, funderlying VARCHAR(128),fts TIMESTAMP, fspot DOUBLE PRECISION)
RETURNS INT AS $$
DECLARE last_aggregation_period BIGINT;
BEGIN
    SELECT EXTRACT(EPOCH FROM ts)::BIGINT -  EXTRACT(EPOCH FROM ts)::BIGINT % (fgranuality) INTO last_aggregation_period FROM feed.realtime_ohlc where underlying=funderlying and granuality=fgranuality;
    IF last_aggregation_period IS NOT NULL THEN
      UPDATE feed.realtime_ohlc SET
          ts=fts,
          high = GREATEST(fspot, high),
          low  = LEAST(fspot, low),
          close = fspot
      WHERE
          underlying = funderlying and granuality = fgranuality;
    ELSE
      DELETE FROM feed.realtime_ohlc WHERE underlying = funderlying and granuality = fgranuality;
      INSERT INTO feed.realtime_ohlc VALUES (fgranuality, funderlying, fts, fspot, fspot, fspot, fspot);
    END IF;
    RETURN 0;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION notify_realtime_ohlc_trigger() RETURNS trigger AS $$
DECLARE
BEGIN
  PERFORM pg_notify('feed_watchers' , NEW.granuality || ',' || NEW.underlying || ',' || NEW.ts || ',' || NEW."open" || ',' || NEW.high || ',' || NEW.low || ',' || NEW."close" );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER watched_ohlc_trigger BEFORE UPDATE OR INSERT ON feed.realtime_ohlc FOR EACH ROW EXECUTE PROCEDURE notify_realtime_ohlc_trigger();

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON ALL TABLES IN SCHEMA feed TO write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed TO write;
COMMIT;

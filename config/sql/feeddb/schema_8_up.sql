BEGIN;

CREATE TABLE feed.realtime_ohlc (
    type VARCHAR(16) NOT NULL,
    underlying VARCHAR(128) NOT NULL,
    ts TIMESTAMP NOT NULL,
    open DOUBLE PRECISION NOT NULL,
    high DOUBLE PRECISION NOT NULL,
    low DOUBLE PRECISION NOT NULL,
    close DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (type,underlying)
);


CREATE OR REPLACE FUNCTION update_realtime_ohlc(ftype VARCHAR(16), funderlying VARCHAR(128),fts TIMESTAMP, fspot DOUBLE PRECISION)
RETURNS INT AS $$
DECLARE last_aggregation_time TIMESTAMP;
BEGIN
    SELECT ts INTO last_aggregation_time FROM feed.realtime_ohlc where underlying=funderlying and type=ftype and  DATE_TRUNC(ftype, fts) = DATE_TRUNC(ftype, ts);
    IF last_aggregation_time IS NOT NULL THEN
      UPDATE feed.realtime_ohlc SET
          ts=fts,
          high = GREATEST(fspot, high),
          low  = LEAST(fspot, low),
          close = fspot
      WHERE
          underlying =funderlying and type =ftype;
    ELSE
      DELETE FROM feed.realtime_ohlc WHERE underlying =funderlying and type =ftype;
      INSERT INTO feed.realtime_ohlc VALUES (ftype, funderlying,fts,fspot,fspot,fspot,fspot);
    END IF;
    RETURN 0;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION notify_realtime_ohlc_trigger() RETURNS trigger AS $$
DECLARE
BEGIN
  PERFORM pg_notify('watchers_ohlc_' || NEW.type || '_' || NEW.underlying, NEW.underlying || ',' || NEW.ts || ',' || NEW."open" || ',' || NEW.high || ',' || NEW.low || ',' || NEW."close" );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER watched_ohlc_trigger BEFORE UPDATE OR INSERT ON feed.realtime_ohlc FOR EACH ROW EXECUTE PROCEDURE notify_realtime_ohlc_trigger();

COMMIT;

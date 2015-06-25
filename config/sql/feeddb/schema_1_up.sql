SET client_min_messages TO warning;

BEGIN;
-- -------------------------------------

CREATE SCHEMA feed;

-- -------------------------------------
-- Creating paritioned tick table (Pre-generated until 2038)
--        - Tables paritioned by month
-- -------------------------------------

CREATE TABLE feed.tick (
    underlying varchar(128) NOT NULL,
    ts timestamp NOT NULL,
    bid double precision NOT NULL,
    ask double precision NOT NULL,
    spot double precision NOT NULL,
    runbet_spot double precision DEFAULT NULL,
    PRIMARY KEY (underlying, ts)
);

CREATE TABLE feed.tick_2011_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-1-1' and ts<'2011-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-2-1' and ts<'2011-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-3-1' and ts<'2011-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-4-1' and ts<'2011-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-5-1' and ts<'2011-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-6-1' and ts<'2011-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-7-1' and ts<'2011-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-8-1' and ts<'2011-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-9-1' and ts<'2011-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-10-1' and ts<'2011-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-11-1' and ts<'2011-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2011_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-12-1' and ts<'2011-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-1-1' and ts<'2012-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-2-1' and ts<'2012-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-3-1' and ts<'2012-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-4-1' and ts<'2012-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-5-1' and ts<'2012-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-6-1' and ts<'2012-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-7-1' and ts<'2012-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-8-1' and ts<'2012-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-9-1' and ts<'2012-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-10-1' and ts<'2012-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-11-1' and ts<'2012-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2012_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-12-1' and ts<'2012-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-1-1' and ts<'2013-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-2-1' and ts<'2013-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-3-1' and ts<'2013-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-4-1' and ts<'2013-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-5-1' and ts<'2013-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-6-1' and ts<'2013-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-7-1' and ts<'2013-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-8-1' and ts<'2013-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-9-1' and ts<'2013-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-10-1' and ts<'2013-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-11-1' and ts<'2013-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2013_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-12-1' and ts<'2013-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-1-1' and ts<'2014-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-2-1' and ts<'2014-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-3-1' and ts<'2014-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-4-1' and ts<'2014-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-5-1' and ts<'2014-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-6-1' and ts<'2014-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-7-1' and ts<'2014-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-8-1' and ts<'2014-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-9-1' and ts<'2014-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-10-1' and ts<'2014-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-11-1' and ts<'2014-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2014_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-12-1' and ts<'2014-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-1-1' and ts<'2015-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-2-1' and ts<'2015-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-3-1' and ts<'2015-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-4-1' and ts<'2015-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-5-1' and ts<'2015-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-6-1' and ts<'2015-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-7-1' and ts<'2015-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-8-1' and ts<'2015-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-9-1' and ts<'2015-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-10-1' and ts<'2015-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-11-1' and ts<'2015-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2015_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-12-1' and ts<'2015-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-1-1' and ts<'2016-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-2-1' and ts<'2016-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-3-1' and ts<'2016-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-4-1' and ts<'2016-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-5-1' and ts<'2016-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-6-1' and ts<'2016-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-7-1' and ts<'2016-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-8-1' and ts<'2016-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-9-1' and ts<'2016-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-10-1' and ts<'2016-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-11-1' and ts<'2016-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2016_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-12-1' and ts<'2016-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-1-1' and ts<'2017-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-2-1' and ts<'2017-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-3-1' and ts<'2017-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-4-1' and ts<'2017-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-5-1' and ts<'2017-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-6-1' and ts<'2017-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-7-1' and ts<'2017-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-8-1' and ts<'2017-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-9-1' and ts<'2017-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-10-1' and ts<'2017-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-11-1' and ts<'2017-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2017_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-12-1' and ts<'2017-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-1-1' and ts<'2018-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-2-1' and ts<'2018-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-3-1' and ts<'2018-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-4-1' and ts<'2018-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-5-1' and ts<'2018-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-6-1' and ts<'2018-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-7-1' and ts<'2018-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-8-1' and ts<'2018-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-9-1' and ts<'2018-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-10-1' and ts<'2018-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-11-1' and ts<'2018-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2018_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-12-1' and ts<'2018-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-1-1' and ts<'2019-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-2-1' and ts<'2019-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-3-1' and ts<'2019-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-4-1' and ts<'2019-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-5-1' and ts<'2019-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-6-1' and ts<'2019-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-7-1' and ts<'2019-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-8-1' and ts<'2019-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-9-1' and ts<'2019-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-10-1' and ts<'2019-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-11-1' and ts<'2019-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2019_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-12-1' and ts<'2019-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-1-1' and ts<'2020-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-2-1' and ts<'2020-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-3-1' and ts<'2020-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-4-1' and ts<'2020-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-5-1' and ts<'2020-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-6-1' and ts<'2020-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-7-1' and ts<'2020-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-8-1' and ts<'2020-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-9-1' and ts<'2020-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-10-1' and ts<'2020-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-11-1' and ts<'2020-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2020_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-12-1' and ts<'2020-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-1-1' and ts<'2021-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-2-1' and ts<'2021-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-3-1' and ts<'2021-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-4-1' and ts<'2021-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-5-1' and ts<'2021-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-6-1' and ts<'2021-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-7-1' and ts<'2021-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-8-1' and ts<'2021-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-9-1' and ts<'2021-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-10-1' and ts<'2021-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-11-1' and ts<'2021-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2021_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-12-1' and ts<'2021-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-1-1' and ts<'2022-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-2-1' and ts<'2022-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-3-1' and ts<'2022-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-4-1' and ts<'2022-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-5-1' and ts<'2022-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-6-1' and ts<'2022-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-7-1' and ts<'2022-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-8-1' and ts<'2022-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-9-1' and ts<'2022-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-10-1' and ts<'2022-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-11-1' and ts<'2022-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2022_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-12-1' and ts<'2022-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-1-1' and ts<'2023-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-2-1' and ts<'2023-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-3-1' and ts<'2023-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-4-1' and ts<'2023-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-5-1' and ts<'2023-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-6-1' and ts<'2023-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-7-1' and ts<'2023-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-8-1' and ts<'2023-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-9-1' and ts<'2023-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-10-1' and ts<'2023-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-11-1' and ts<'2023-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2023_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-12-1' and ts<'2023-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-1-1' and ts<'2024-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-2-1' and ts<'2024-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-3-1' and ts<'2024-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-4-1' and ts<'2024-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-5-1' and ts<'2024-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-6-1' and ts<'2024-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-7-1' and ts<'2024-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-8-1' and ts<'2024-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-9-1' and ts<'2024-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-10-1' and ts<'2024-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-11-1' and ts<'2024-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2024_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-12-1' and ts<'2024-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-1-1' and ts<'2025-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-2-1' and ts<'2025-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-3-1' and ts<'2025-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-4-1' and ts<'2025-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-5-1' and ts<'2025-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-6-1' and ts<'2025-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-7-1' and ts<'2025-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-8-1' and ts<'2025-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-9-1' and ts<'2025-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-10-1' and ts<'2025-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-11-1' and ts<'2025-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2025_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-12-1' and ts<'2025-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-1-1' and ts<'2026-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-2-1' and ts<'2026-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-3-1' and ts<'2026-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-4-1' and ts<'2026-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-5-1' and ts<'2026-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-6-1' and ts<'2026-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-7-1' and ts<'2026-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-8-1' and ts<'2026-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-9-1' and ts<'2026-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-10-1' and ts<'2026-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-11-1' and ts<'2026-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2026_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-12-1' and ts<'2026-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-1-1' and ts<'2027-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-2-1' and ts<'2027-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-3-1' and ts<'2027-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-4-1' and ts<'2027-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-5-1' and ts<'2027-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-6-1' and ts<'2027-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-7-1' and ts<'2027-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-8-1' and ts<'2027-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-9-1' and ts<'2027-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-10-1' and ts<'2027-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-11-1' and ts<'2027-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2027_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-12-1' and ts<'2027-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-1-1' and ts<'2028-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-2-1' and ts<'2028-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-3-1' and ts<'2028-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-4-1' and ts<'2028-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-5-1' and ts<'2028-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-6-1' and ts<'2028-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-7-1' and ts<'2028-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-8-1' and ts<'2028-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-9-1' and ts<'2028-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-10-1' and ts<'2028-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-11-1' and ts<'2028-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2028_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-12-1' and ts<'2028-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-1-1' and ts<'2029-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-2-1' and ts<'2029-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-3-1' and ts<'2029-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-4-1' and ts<'2029-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-5-1' and ts<'2029-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-6-1' and ts<'2029-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-7-1' and ts<'2029-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-8-1' and ts<'2029-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-9-1' and ts<'2029-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-10-1' and ts<'2029-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-11-1' and ts<'2029-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2029_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-12-1' and ts<'2029-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-1-1' and ts<'2030-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-2-1' and ts<'2030-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-3-1' and ts<'2030-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-4-1' and ts<'2030-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-5-1' and ts<'2030-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-6-1' and ts<'2030-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-7-1' and ts<'2030-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-8-1' and ts<'2030-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-9-1' and ts<'2030-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-10-1' and ts<'2030-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-11-1' and ts<'2030-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2030_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-12-1' and ts<'2030-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-1-1' and ts<'2031-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-2-1' and ts<'2031-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-3-1' and ts<'2031-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-4-1' and ts<'2031-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-5-1' and ts<'2031-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-6-1' and ts<'2031-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-7-1' and ts<'2031-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-8-1' and ts<'2031-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-9-1' and ts<'2031-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-10-1' and ts<'2031-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-11-1' and ts<'2031-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2031_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-12-1' and ts<'2031-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-1-1' and ts<'2032-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-2-1' and ts<'2032-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-3-1' and ts<'2032-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-4-1' and ts<'2032-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-5-1' and ts<'2032-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-6-1' and ts<'2032-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-7-1' and ts<'2032-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-8-1' and ts<'2032-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-9-1' and ts<'2032-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-10-1' and ts<'2032-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-11-1' and ts<'2032-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2032_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-12-1' and ts<'2032-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-1-1' and ts<'2033-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-2-1' and ts<'2033-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-3-1' and ts<'2033-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-4-1' and ts<'2033-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-5-1' and ts<'2033-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-6-1' and ts<'2033-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-7-1' and ts<'2033-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-8-1' and ts<'2033-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-9-1' and ts<'2033-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-10-1' and ts<'2033-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-11-1' and ts<'2033-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2033_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-12-1' and ts<'2033-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-1-1' and ts<'2034-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-2-1' and ts<'2034-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-3-1' and ts<'2034-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-4-1' and ts<'2034-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-5-1' and ts<'2034-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-6-1' and ts<'2034-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-7-1' and ts<'2034-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-8-1' and ts<'2034-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-9-1' and ts<'2034-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-10-1' and ts<'2034-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-11-1' and ts<'2034-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2034_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-12-1' and ts<'2034-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-1-1' and ts<'2035-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-2-1' and ts<'2035-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-3-1' and ts<'2035-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-4-1' and ts<'2035-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-5-1' and ts<'2035-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-6-1' and ts<'2035-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-7-1' and ts<'2035-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-8-1' and ts<'2035-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-9-1' and ts<'2035-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-10-1' and ts<'2035-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-11-1' and ts<'2035-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2035_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-12-1' and ts<'2035-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-1-1' and ts<'2036-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-2-1' and ts<'2036-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-3-1' and ts<'2036-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-4-1' and ts<'2036-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-5-1' and ts<'2036-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-6-1' and ts<'2036-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-7-1' and ts<'2036-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-8-1' and ts<'2036-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-9-1' and ts<'2036-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-10-1' and ts<'2036-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-11-1' and ts<'2036-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2036_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-12-1' and ts<'2036-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-1-1' and ts<'2037-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-2-1' and ts<'2037-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-3-1' and ts<'2037-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-4-1' and ts<'2037-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-5-1' and ts<'2037-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-6-1' and ts<'2037-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-7-1' and ts<'2037-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-8-1' and ts<'2037-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-9-1' and ts<'2037-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-10-1' and ts<'2037-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-11-1' and ts<'2037-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2037_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-12-1' and ts<'2037-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_1 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-1-1' and ts<'2038-1-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_2 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-2-1' and ts<'2038-2-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_3 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-3-1' and ts<'2038-3-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_4 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-4-1' and ts<'2038-4-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_5 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-5-1' and ts<'2038-5-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_6 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-6-1' and ts<'2038-6-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_7 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-7-1' and ts<'2038-7-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_8 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-8-1' and ts<'2038-8-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_9 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-9-1' and ts<'2038-9-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_10 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-10-1' and ts<'2038-10-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_11 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-11-1' and ts<'2038-11-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

CREATE TABLE feed.tick_2038_12 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-12-1' and ts<'2038-12-1'::DATE + interval '1 month'),
    CHECK(DATE_TRUNC('second', ts) = ts)
)
INHERITS (feed.tick);

-- -------------------------------------
-- Creating paritioned ohlc_minutely table (Pre-generated until 2038)
--        - Tables paritioned by year
-- -------------------------------------

CREATE TABLE feed.ohlc_minutely (
    underlying VARCHAR(128) NOT NULL,
    ts TIMESTAMP NOT NULL,
    open double precision NOT NULL,
    high double precision NOT NULL,
    low double precision NOT NULL,
    close double precision NOT NULL,
    PRIMARY KEY (underlying, ts),
    CONSTRAINT high_open_check CHECK(high >= open),
    CONSTRAINT high_close_check CHECK(high >= close),
    CONSTRAINT low_open_check CHECK(low <= open),
    CONSTRAINT low_close_check CHECK(low <= close),
    CONSTRAINT high_low_check CHECK(high >= low)
);

CREATE TABLE feed.ohlc_minutely_2000 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2000-1-1' and ts<'2000-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2001 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2001-1-1' and ts<'2001-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2002 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2002-1-1' and ts<'2002-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2003 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2003-1-1' and ts<'2003-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2004 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2004-1-1' and ts<'2004-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2005 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2005-1-1' and ts<'2005-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2006 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2006-1-1' and ts<'2006-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2007 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2007-1-1' and ts<'2007-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2008 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2008-1-1' and ts<'2008-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2009 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2009-1-1' and ts<'2009-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2010 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2010-1-1' and ts<'2010-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2011 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2011-1-1' and ts<'2011-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2012 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2012-1-1' and ts<'2012-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2013 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2013-1-1' and ts<'2013-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2014 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2014-1-1' and ts<'2014-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2015 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2015-1-1' and ts<'2015-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2016 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2016-1-1' and ts<'2016-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2017 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2017-1-1' and ts<'2017-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2018 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2018-1-1' and ts<'2018-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2019 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2019-1-1' and ts<'2019-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2020 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2020-1-1' and ts<'2020-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2021 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2021-1-1' and ts<'2021-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2022 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2022-1-1' and ts<'2022-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2023 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2023-1-1' and ts<'2023-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2024 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2024-1-1' and ts<'2024-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2025 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2025-1-1' and ts<'2025-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2026 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2026-1-1' and ts<'2026-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2027 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2027-1-1' and ts<'2027-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2028 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2028-1-1' and ts<'2028-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2029 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2029-1-1' and ts<'2029-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2030 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2030-1-1' and ts<'2030-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2031 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2031-1-1' and ts<'2031-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2032 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2032-1-1' and ts<'2032-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2033 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2033-1-1' and ts<'2033-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2034 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2034-1-1' and ts<'2034-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2035 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2035-1-1' and ts<'2035-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2036 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2036-1-1' and ts<'2036-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2037 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2037-1-1' and ts<'2037-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_minutely_2038 (
    PRIMARY KEY (underlying, ts),
    CHECK(ts>= '2038-1-1' and ts<'2038-1-1'::DATE + interval '1 year')
)
INHERITS (feed.ohlc_minutely);

CREATE TABLE feed.ohlc_hourly (
    underlying VARCHAR(128) NOT NULL,
    ts TIMESTAMP NOT NULL,
    open double precision NOT NULL,
    high double precision NOT NULL,
    low double precision NOT NULL,
    close double precision NOT NULL,
    PRIMARY KEY (underlying, ts),
    CONSTRAINT high_open_check CHECK(high >= open),
    CONSTRAINT high_close_check CHECK(high >= close),
    CONSTRAINT low_open_check CHECK(low <= open),
    CONSTRAINT low_close_check CHECK(low <= close),
    CONSTRAINT high_low_check CHECK(high >= low)
);

CREATE TABLE feed.ohlc_daily (
    underlying VARCHAR(128),
    ts TIMESTAMP,
    open double precision NOT NULL,
    high double precision NOT NULL,
    low double precision NOT NULL,
    close double precision NOT NULL,
    official bool default false,
    PRIMARY KEY (underlying, ts, official),
    CONSTRAINT high_open_check CHECK(high >= open),
    CONSTRAINT high_close_check CHECK(high >= close),
    CONSTRAINT low_open_check CHECK(low <= open),
    CONSTRAINT low_close_check CHECK(low <= close),
    CONSTRAINT high_low_check CHECK(high >=low)
);

CREATE TABLE feed.ohlc_status (
    underlying VARCHAR(128) NOT NULL,
    last_time TIMESTAMP NOT NULL,
    type varchar(16) NOT NULL,
    PRIMARY KEY (underlying, type)
);

-- grant Role
GRANT USAGE ON SCHEMA feed TO read;
GRANT USAGE ON SCHEMA feed TO write;
GRANT USAGE ON SCHEMA feed TO monitor;

COMMIT;

BEGIN;

CREATE OR REPLACE FUNCTION data_collection.calculate_affiliate_commission (start_date TIMESTAMP, end_date TIMESTAMP)
RETURNS TABLE (inserted_cnt BIGINT) AS $SQL$

WITH turnover_pnl as (
    SELECT rem.*
    FROM
        betonmarkets.production_servers() s,
        data_collection.get_affiliate_commission_on(s.srvname, $1, $2) rem
),
total_turnover_pnl as (
    SELECT
        user_id,
        username,
        effective_date,
        sum(intraday_turnover) as intraday_turnover,
        sum(runbet_turnover) as runbet_turnover,
        sum(other_turnover) as other_turnover,
        sum(pnl) as pnl
    FROM
        turnover_pnl t,
        data_collection.myaffiliates_token_details m
    WHERE
        t.myaffiliates_token = m.token
    GROUP BY 1,2,3
),
previous_agg as (
    SELECT
        affiliate_userid,
        affiliate_username,
        last(effective_pnl_for_commission ORDER BY effective_date) as pnl_for_commission,
        last(carry_over_to_next_month ORDER BY effective_date) as carry_over
    FROM
        data_collection.myaffiliates_commission
    WHERE
        effective_date < $1
    GROUP BY 1,2
),
ins as (
    INSERT INTO data_collection.myaffiliates_commission (
        affiliate_userid,
        affiliate_username,
        effective_date,
        intraday_turnover,
        runbet_turnover,
        other_turnover,
        pnl,
        effective_pnl_for_commission,
        carry_over_to_next_month,
        commission
    )

    SELECT
        user_id,
        username,
        effective_date,
        intraday_turnover,
        runbet_turnover,
        other_turnover,
        pnl,
        effective_pnl_for_commission,
        carry_over_to_next_month,
        CASE
            WHEN effective_pnl_for_commission <= 10000 THEN effective_pnl_for_commission * 0.2
            WHEN effective_pnl_for_commission <= 50000 THEN 2000 + (effective_pnl_for_commission - 10000) * 0.25
            WHEN effective_pnl_for_commission <= 100000 THEN 12000 + (effective_pnl_for_commission - 50000) * 0.3
            ELSE 27000 + (effective_pnl_for_commission - 100000) * 0.35
        END as commission
    FROM
    (
        SELECT
            t.user_id,
            t.username,
            t.effective_date,
            intraday_turnover,
            runbet_turnover,
            other_turnover,
            pnl,
            CASE
                WHEN p.pnl_for_commission IS NOT NULL THEN
                (
                    CASE WHEN p.pnl_for_commission > 0 THEN
                        CASE WHEN pnl > 0 THEN pnl ELSE 0 END
                    ELSE
                        CASE WHEN (p.carry_over + pnl) > 0 THEN (p.carry_over + pnl) ELSE 0 END
                    END
                )
                ELSE
                    CASE WHEN pnl > 0 THEN pnl ELSE 0 END
            END as effective_pnl_for_commission,
            CASE
                WHEN p.carry_over IS NOT NULL THEN
                (
                    CASE WHEN (p.carry_over + pnl) < 0 THEN p.carry_over + pnl
                    ELSE 0
                    END
                )
                ELSE
                (
                    CASE WHEN pnl < 0 THEN pnl
                    ELSE 0
                    END
                )
            END as carry_over_to_next_month
        FROM
            total_turnover_pnl t
            LEFT JOIN previous_agg p
                ON t.user_id = p.affiliate_userid AND t.username = p.affiliate_username
        ORDER BY 1,2,3
    ) t
    RETURNING id
)

SELECT count(*) as inserted_cnt FROM ins;

$SQL$
LANGUAGE sql VOLATILE;

COMMIT;

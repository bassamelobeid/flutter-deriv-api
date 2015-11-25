BEGIN;

CREATE TABLE payment.inter_cluster_transfer_queue (
    payment_id         BIGINT PRIMARY KEY
                              REFERENCES payment.payment(id)
                                  ON DELETE RESTRICT
                                  ON UPDATE RESTRICT,
    recipient_loginid  VARCHAR(12),
    staff_loginid      VARCHAR(12),
    remark             VARCHAR(800),
    limits             JSON
);

CREATE OR REPLACE FUNCTION payment.inter_cluster_transfer_queue_notify () RETURNS trigger AS $def$
BEGIN
    NOTIFY inter_cluster_transfer_queue;
    RETURN NULL;
END
$def$ LANGUAGE plpgsql VOLATILE;

CREATE TRIGGER inter_cluster_transfer_queue_notify_trg AFTER INSERT
    ON payment.inter_cluster_transfer_queue FOR EACH STATEMENT
    EXECUTE PROCEDURE payment.inter_cluster_transfer_queue_notify();

CREATE TABLE payment.inter_cluster_transfer_log (
    payment_id                BIGINT PRIMARY KEY
                                     REFERENCES payment.payment(id)
                                         ON DELETE RESTRICT
                                         ON UPDATE RESTRICT,
    recipient_loginid         VARCHAR(12),
    corresponding_payment_id  BIGINT,
    UNIQUE(recipient_loginid, corresponding_payment_id)
);

COMMIT;

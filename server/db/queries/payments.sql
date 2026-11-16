-- name: CreatePayment :one
INSERT INTO payments (id, event_id, account_id, kind, package_size, amount_halalas, currency, provider, provider_ref)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetPayment :one
SELECT * FROM payments WHERE id = $1;

-- name: GetPaymentByProviderRef :one
SELECT * FROM payments WHERE provider = $1 AND provider_ref = $2;

-- Only a pending payment can be marked paid; returns no row if it was already handled,
-- so a repeated provider callback does nothing. Apply the package size in the same transaction.
-- name: MarkPaymentPaid :one
UPDATE payments SET status = 'paid', paid_at = now()
WHERE id = $1 AND status = 'pending'
RETURNING *;

-- name: MarkPaymentFailed :one
UPDATE payments SET status = 'failed'
WHERE id = $1 AND status = 'pending'
RETURNING *;

-- name: ListPaymentsByEvent :many
SELECT * FROM payments WHERE event_id = $1 ORDER BY created_at;

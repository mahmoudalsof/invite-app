-- name: CreateAccount :one
INSERT INTO accounts (id, display_name, phone, email, language)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetAccount :one
SELECT * FROM accounts WHERE id = $1;

-- name: GetAccountByPhone :one
SELECT * FROM accounts WHERE phone = $1;

-- Dev sign-in: return the account for this phone, creating it if needed.
-- The id is used only when the account is new.
-- name: UpsertAccountByPhone :one
INSERT INTO accounts (id, display_name, phone, language)
VALUES ($1, $2, $3, $4)
ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
RETURNING *;

-- name: UpdateAccountProfile :one
UPDATE accounts SET display_name = $2, language = $3
WHERE id = $1
RETURNING *;

-- name: CreateEvent :one
INSERT INTO events (id, owner_account_id, type, title, event_date, starts_at, venue_name, venue_map_url, attendance)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetEvent :one
SELECT * FROM events WHERE id = $1;

-- Locks the event row for the rest of the transaction (same lock the package-limit trigger takes).
-- name: GetEventForUpdate :one
SELECT * FROM events WHERE id = $1 FOR UPDATE;

-- Events the account owns or has any role on, newest first.
-- name: ListEventsForAccount :many
SELECT e.* FROM events e
WHERE e.owner_account_id = @account_id
   OR EXISTS (SELECT 1 FROM event_roles r WHERE r.event_id = e.id AND r.account_id = @account_id)
ORDER BY e.created_at DESC;

-- name: UpdateEventDetails :one
UPDATE events
SET title = $2, event_date = $3, starts_at = $4, venue_name = $5, venue_map_url = $6, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: SetEventStatus :one
UPDATE events SET status = $2, updated_at = now()
WHERE id = $1
RETURNING *;

-- Sets the package size, but never below the number of guests already added.
-- Returns no row (pgx.ErrNoRows) if the new size is too small.
-- name: SetEventPackageSize :one
UPDATE events e SET package_size = @package_size, updated_at = now()
WHERE e.id = @id
  AND @package_size::int >= (SELECT count(*) FROM guests g WHERE g.event_id = e.id)
RETURNING *;

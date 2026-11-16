-- name: CreateWalkInRequest :one
INSERT INTO walk_in_requests (id, event_id, section_id, guest_name, relation, children_count, requested_by)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetWalkInRequest :one
SELECT * FROM walk_in_requests WHERE id = $1;

-- name: ListWalkInRequestsByEvent :many
SELECT * FROM walk_in_requests
WHERE event_id = $1 AND (sqlc.narg(status)::text IS NULL OR status = sqlc.narg(status))
ORDER BY created_at DESC;

-- name: ListWalkInRequestsBySection :many
SELECT * FROM walk_in_requests
WHERE section_id = $1
ORDER BY created_at DESC;

-- Only a pending request can be decided; returns no row if it was already decided.
-- name: DecideWalkInRequest :one
UPDATE walk_in_requests
SET status = @status, decided_by = @decided_by, decided_at = now()
WHERE id = @id AND status = 'pending'
RETURNING *;

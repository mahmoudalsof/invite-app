-- name: CreateSection :one
INSERT INTO sections (id, event_id, kind) VALUES ($1, $2, $3)
RETURNING *;

-- name: GetSection :one
SELECT * FROM sections WHERE id = $1;

-- name: ListSections :many
SELECT * FROM sections WHERE event_id = $1 ORDER BY kind;

-- name: DeleteSection :exec
DELETE FROM sections WHERE id = $1;

-- Only the SHA-256 hash of a session token is ever stored or looked up.

-- name: CreateSession :one
INSERT INTO sessions (id, token_hash, kind, account_id, door_role_id, expires_at)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: GetActiveSession :one
SELECT * FROM sessions
WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now();

-- name: RevokeSession :exec
UPDATE sessions SET revoked_at = now()
WHERE id = $1 AND revoked_at IS NULL;

-- Ends every door session for a role, e.g. when the host removes a door team member.
-- name: RevokeDoorRoleSessions :exec
UPDATE sessions SET revoked_at = now()
WHERE door_role_id = $1 AND revoked_at IS NULL;

-- name: DeleteExpiredSessions :execrows
DELETE FROM sessions WHERE expires_at < now() - interval '7 days';

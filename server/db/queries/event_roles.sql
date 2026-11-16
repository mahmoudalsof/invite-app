-- name: CreateEventRole :one
INSERT INTO event_roles (id, event_id, account_id, role, section_id, invite_quota)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: GetEventRole :one
SELECT * FROM event_roles WHERE id = $1;

-- name: ListEventRoles :many
SELECT * FROM event_roles WHERE event_id = $1 ORDER BY created_at;

-- All roles one account holds on one event; the server's permission checks start here.
-- name: ListAccountRolesForEvent :many
SELECT * FROM event_roles WHERE event_id = $1 AND account_id = $2;

-- A door team member opens their WhatsApp link and signs in. Only an unclaimed door role can be claimed.
-- name: ClaimDoorRole :one
UPDATE event_roles SET account_id = $2
WHERE id = $1 AND role = 'door' AND account_id IS NULL
RETURNING *;

-- name: UpdateInviteQuota :one
UPDATE event_roles SET invite_quota = $2
WHERE id = $1 AND role = 'inviter'
RETURNING *;

-- name: DeleteEventRole :exec
DELETE FROM event_roles WHERE id = $1;

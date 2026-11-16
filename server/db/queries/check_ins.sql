-- Door phones generate the check-in id, so a retried sync is harmless.
-- ON CONFLICT DO NOTHING covers both a repeated id and a second 'admitted' scan
-- (check_ins_one_admit_idx). On conflict no row comes back (pgx.ErrNoRows): the server then
-- checks GetCheckIn for a retry, otherwise stores the scan as 'already_used' (first admit wins).
-- name: InsertCheckIn :one
INSERT INTO check_ins (id, event_id, section_id, invitation_id, door_role_id, device_id, scanned_at, result)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT DO NOTHING
RETURNING *;

-- name: GetCheckIn :one
SELECT * FROM check_ins WHERE id = $1;

-- name: GetAdmittedCheckIn :one
SELECT * FROM check_ins WHERE invitation_id = $1 AND result = 'admitted';

-- Scans other phones in the section have synced since the cursor.
-- synced_at is set at insert, but transactions can commit out of order, so clients
-- should move the cursor back a few seconds and de-duplicate by id.
-- name: ListCheckInsSince :many
SELECT * FROM check_ins
WHERE section_id = @section_id AND synced_at > @since
ORDER BY synced_at, id
LIMIT @max_rows;

-- name: CountAdmittedBySection :many
SELECT section_id, count(*)::int AS admitted
FROM check_ins
WHERE event_id = $1 AND result = 'admitted'
GROUP BY section_id;

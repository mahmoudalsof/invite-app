-- Inserts fail with constraint guests_package_limit (SQLSTATE 23514) when the package is full,
-- and with guests_event_id_phone_key (23505) when the phone is already on this event.

-- name: CreateGuest :one
INSERT INTO guests (id, event_id, section_id, full_name, phone, language, children_count, invited_by)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetGuest :one
SELECT * FROM guests WHERE id = $1;

-- name: ListGuestsBySection :many
SELECT * FROM guests WHERE section_id = $1 ORDER BY full_name, id;

-- name: ListGuestsInvitedBy :many
SELECT * FROM guests WHERE invited_by = $1 ORDER BY full_name, id;

-- Counts only: what a host or men's door team sees for a women's section.
-- name: CountGuestsBySection :many
SELECT s.id AS section_id, s.kind,
       count(g.id)::int AS guests,
       coalesce(sum(g.children_count), 0)::int AS children
FROM sections s
LEFT JOIN guests g ON g.section_id = s.id
WHERE s.event_id = $1
GROUP BY s.id, s.kind
ORDER BY s.kind;

-- name: CountGuestsForEvent :one
SELECT count(*)::int FROM guests WHERE event_id = $1;

-- For an inviter's quota check. Call inside the same transaction as CreateGuest,
-- after GetEventForUpdate, so two inviters cannot both take the last place.
-- name: CountGuestsInvitedBy :one
SELECT count(*)::int FROM guests WHERE invited_by = $1;

-- name: UpdateGuest :one
UPDATE guests
SET section_id = $2, full_name = $3, phone = $4, language = $5, children_count = $6
WHERE id = $1
RETURNING *;

-- name: DeleteGuest :exec
DELETE FROM guests WHERE id = $1;

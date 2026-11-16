-- name: CreateInvitation :one
INSERT INTO invitations (id, guest_id, public_token) VALUES ($1, $2, $3)
RETURNING *;

-- name: GetInvitation :one
SELECT * FROM invitations WHERE id = $1;

-- Everything the guest page needs, looked up by the token in the URL.
-- name: GetInvitationPage :one
SELECT sqlc.embed(i), sqlc.embed(g), sqlc.embed(s), sqlc.embed(e)
FROM invitations i
JOIN guests g   ON g.id = i.guest_id
JOIN sections s ON s.id = g.section_id
JOIN events e   ON e.id = g.event_id
WHERE i.public_token = $1;

-- Children attending can never be more than the children on the invitation.
-- Returns no row if the token is unknown or the count is too high.
-- name: SetRSVP :one
UPDATE invitations i
SET rsvp = @rsvp, rsvp_at = now(), children_attending = @children_attending
FROM guests g
WHERE g.id = i.guest_id
  AND i.public_token = @public_token
  AND @children_attending::int <= g.children_count
RETURNING i.*;

-- Guests on the event who have no invitation row yet.
-- name: ListGuestsWithoutInvitation :many
SELECT g.* FROM guests g
LEFT JOIN invitations i ON i.guest_id = g.id
WHERE g.event_id = $1 AND i.id IS NULL
ORDER BY g.created_at, g.id;

-- Invitations whose invitation message has not been sent (or only failed), for a sending wave.
-- name: ListInvitationsToSend :many
SELECT i.id AS invitation_id, i.public_token, g.id AS guest_id, g.full_name, g.phone, g.language, g.section_id
FROM invitations i
JOIN guests g ON g.id = i.guest_id
WHERE g.event_id = @event_id
  AND NOT EXISTS (
      SELECT 1 FROM messages m
      WHERE m.guest_id = g.id AND m.direction = 'out' AND m.purpose = 'invitation' AND m.status <> 'failed'
  )
ORDER BY g.created_at, g.id
LIMIT @max_rows;

-- The list a door phone downloads before the event: its own section only.
-- name: ListDoorPasses :many
SELECT i.id AS invitation_id, g.full_name, g.children_count, i.rsvp, i.children_attending,
       EXISTS (SELECT 1 FROM check_ins c WHERE c.invitation_id = i.id AND c.result = 'admitted') AS admitted
FROM invitations i
JOIN guests g ON g.id = i.guest_id
WHERE g.section_id = $1
ORDER BY g.full_name, i.id;

-- name: UpsertMessageTemplate :one
INSERT INTO message_templates (id, event_id, purpose, language, body, meta_template_name)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (event_id, purpose, language)
DO UPDATE SET body = EXCLUDED.body, meta_template_name = EXCLUDED.meta_template_name, updated_at = now()
RETURNING *;

-- name: ListMessageTemplates :many
SELECT * FROM message_templates WHERE event_id = $1 ORDER BY purpose, language;

-- name: CreateMessage :one
INSERT INTO messages (id, event_id, guest_id, direction, purpose, language, provider_message_id, status)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: MarkMessageSent :one
UPDATE messages SET provider_message_id = $2, status = 'sent', updated_at = now()
WHERE id = $1
RETURNING *;

-- name: MarkMessageFailed :one
UPDATE messages SET status = 'failed', error = $2, updated_at = now()
WHERE id = $1
RETURNING *;

-- Delivery status from the WhatsApp webhook. Statuses can arrive out of order,
-- so a message only moves forward (sent → delivered → read); 'failed' always applies.
-- name: UpdateMessageStatusByProviderID :one
UPDATE messages SET status = @status, error = @error, updated_at = now()
WHERE provider_message_id = @provider_message_id
  AND (@status::text = 'failed'
       OR array_position(ARRAY['queued','sent','delivered','read'], @status::text)
          > array_position(ARRAY['queued','sent','delivered','read'], status))
RETURNING *;

-- name: CountMessagesByStatus :many
SELECT status, count(*)::int AS messages
FROM messages
WHERE event_id = $1 AND direction = 'out' AND purpose = $2
GROUP BY status;

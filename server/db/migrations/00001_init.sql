-- +goose Up
-- Core schema for the invitation and check-in service.
-- IDs are UUID v7, generated in Go (google/uuid), so tables have no ID default.

CREATE TABLE accounts (
    id            uuid PRIMARY KEY,
    display_name  text        NOT NULL DEFAULT '',
    phone         text UNIQUE,                       -- E.164, e.g. +9665XXXXXXXX
    email         text,
    apple_sub     text UNIQUE,                       -- Sign in with Apple subject
    google_sub    text UNIQUE,                       -- Google subject
    language      text        NOT NULL DEFAULT 'ar' CHECK (language IN ('ar', 'en')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Phone sign-in codes. Only a hash of the code is stored.
CREATE TABLE otp_codes (
    id          uuid PRIMARY KEY,
    phone       text        NOT NULL,
    code_hash   bytea       NOT NULL,
    attempts    int         NOT NULL DEFAULT 0,
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_codes_phone_idx ON otp_codes (phone, created_at DESC);

CREATE TABLE events (
    id                uuid PRIMARY KEY,
    owner_account_id  uuid        NOT NULL REFERENCES accounts (id),
    type              text        NOT NULL CHECK (type IN ('wedding', 'engagement')),
    title             text        NOT NULL DEFAULT '',
    event_date        date,                          -- optional until sending
    starts_at         timestamptz,
    venue_name        text        NOT NULL DEFAULT '',
    venue_map_url     text        NOT NULL DEFAULT '',
    attendance        text        NOT NULL CHECK (attendance IN ('men', 'women', 'both')),
    package_size      int         NOT NULL DEFAULT 0 CHECK (package_size >= 0), -- adult guests across all sections
    status            text        NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'paid', 'testing', 'scheduled', 'sending', 'live', 'closed')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX events_owner_idx ON events (owner_account_id);

-- One row per gate: an event has a men's section, a women's section, or both.
CREATE TABLE sections (
    id        uuid PRIMARY KEY,
    event_id  uuid NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    kind      text NOT NULL CHECK (kind IN ('men', 'women')),
    UNIQUE (event_id, kind)
);

-- Who can do what on an event. Door roles are scoped to one section.
CREATE TABLE event_roles (
    id            uuid PRIMARY KEY,
    event_id      uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    account_id    uuid        REFERENCES accounts (id),   -- null until a door link is claimed
    role          text        NOT NULL CHECK (role IN ('host', 'cohost', 'section_manager', 'inviter', 'door')),
    section_id    uuid        REFERENCES sections (id) ON DELETE CASCADE,
    invite_quota  int         CHECK (invite_quota IS NULL OR invite_quota >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (role NOT IN ('section_manager', 'door') OR section_id IS NOT NULL)
);
CREATE INDEX event_roles_event_idx ON event_roles (event_id);
CREATE INDEX event_roles_account_idx ON event_roles (account_id);

-- One row per adult guest. Children travel on the same invitation.
CREATE TABLE guests (
    id              uuid PRIMARY KEY,
    event_id        uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    section_id      uuid        NOT NULL REFERENCES sections (id) ON DELETE CASCADE,
    full_name       text        NOT NULL,
    phone           text        NOT NULL,
    language        text        NOT NULL DEFAULT 'ar' CHECK (language IN ('ar', 'en')),
    children_count  int         NOT NULL DEFAULT 0 CHECK (children_count BETWEEN 0 AND 20),
    invited_by      uuid        REFERENCES event_roles (id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, phone)
);
CREATE INDEX guests_section_idx ON guests (section_id);

-- The package limit must never be exceeded, even under concurrent inserts.
-- Locking the event row serialises inserts for one event.
-- +goose StatementBegin
CREATE FUNCTION enforce_package_limit() RETURNS trigger AS $$
DECLARE
    limit_size int;
    current_count int;
BEGIN
    SELECT package_size INTO limit_size FROM events WHERE id = NEW.event_id FOR UPDATE;
    SELECT count(*) INTO current_count FROM guests WHERE event_id = NEW.event_id;
    IF current_count >= limit_size THEN
        RAISE EXCEPTION 'package limit reached for event %', NEW.event_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'guests_package_limit';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

CREATE TRIGGER guests_package_limit
    BEFORE INSERT ON guests
    FOR EACH ROW EXECUTE FUNCTION enforce_package_limit();

CREATE TABLE invitations (
    id                  uuid PRIMARY KEY,
    guest_id            uuid        NOT NULL UNIQUE REFERENCES guests (id) ON DELETE CASCADE,
    public_token        text        NOT NULL UNIQUE,     -- random, used in the guest page URL
    rsvp                text        NOT NULL DEFAULT 'pending' CHECK (rsvp IN ('pending', 'accepted', 'declined')),
    rsvp_at             timestamptz,
    children_attending  int         NOT NULL DEFAULT 0 CHECK (children_attending >= 0),
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- The host's own wording, per language and purpose.
CREATE TABLE message_templates (
    id                  uuid PRIMARY KEY,
    event_id            uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    purpose             text        NOT NULL CHECK (purpose IN ('invitation', 'reminder', 'pass', 'thanks')),
    language            text        NOT NULL CHECK (language IN ('ar', 'en')),
    body                text        NOT NULL DEFAULT '',
    meta_template_name  text        NOT NULL DEFAULT '',
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, purpose, language)
);

-- Every WhatsApp message sent or received.
CREATE TABLE messages (
    id                   uuid PRIMARY KEY,
    event_id             uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    guest_id             uuid        REFERENCES guests (id) ON DELETE SET NULL,
    direction            text        NOT NULL CHECK (direction IN ('out', 'in')),
    purpose              text        NOT NULL DEFAULT '',
    language             text        NOT NULL DEFAULT 'ar',
    provider_message_id  text UNIQUE,
    status               text        NOT NULL DEFAULT 'queued'
                         CHECK (status IN ('queued', 'sent', 'delivered', 'read', 'failed')),
    error                text        NOT NULL DEFAULT '',
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_event_idx ON messages (event_id, created_at DESC);

-- Scans recorded by door phones (often offline, synced later).
CREATE TABLE check_ins (
    id             uuid PRIMARY KEY,
    event_id       uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    section_id     uuid        NOT NULL REFERENCES sections (id) ON DELETE CASCADE,
    invitation_id  uuid        NOT NULL REFERENCES invitations (id) ON DELETE CASCADE,
    door_role_id   uuid        REFERENCES event_roles (id) ON DELETE SET NULL,
    device_id      text        NOT NULL DEFAULT '',
    scanned_at     timestamptz NOT NULL,              -- time on the door phone
    result         text        NOT NULL CHECK (result IN ('admitted', 'already_used', 'wrong_section')),
    synced_at      timestamptz NOT NULL DEFAULT now()
);
-- First admitted scan wins: a pass can be admitted only once.
CREATE UNIQUE INDEX check_ins_one_admit_idx ON check_ins (invitation_id) WHERE result = 'admitted';
CREATE INDEX check_ins_event_idx ON check_ins (event_id, scanned_at DESC);

-- Guests not on the list, approved by the host from the app.
CREATE TABLE walk_in_requests (
    id              uuid PRIMARY KEY,
    event_id        uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    section_id      uuid        NOT NULL REFERENCES sections (id) ON DELETE CASCADE,
    guest_name      text        NOT NULL,
    relation        text        NOT NULL DEFAULT '',
    children_count  int         NOT NULL DEFAULT 0 CHECK (children_count BETWEEN 0 AND 20),
    status          text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined')),
    requested_by    uuid        REFERENCES event_roles (id) ON DELETE SET NULL,
    decided_by      uuid        REFERENCES accounts (id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    decided_at      timestamptz
);
CREATE INDEX walk_in_requests_event_idx ON walk_in_requests (event_id, status);

CREATE TABLE payments (
    id               uuid PRIMARY KEY,
    event_id         uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    account_id       uuid        NOT NULL REFERENCES accounts (id),
    kind             text        NOT NULL CHECK (kind IN ('package', 'upgrade')),
    package_size     int         NOT NULL CHECK (package_size > 0),   -- size after this payment
    amount_halalas   bigint      NOT NULL CHECK (amount_halalas >= 0),
    currency         text        NOT NULL DEFAULT 'SAR',
    provider         text        NOT NULL,                             -- 'fake', 'moyasar', ...
    provider_ref     text        NOT NULL DEFAULT '',
    status           text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'failed', 'refunded')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    paid_at          timestamptz
);
CREATE INDEX payments_event_idx ON payments (event_id);

-- Opaque session tokens. Only a SHA-256 hash of the token is stored.
CREATE TABLE sessions (
    id            uuid PRIMARY KEY,
    token_hash    bytea       NOT NULL UNIQUE,
    kind          text        NOT NULL CHECK (kind IN ('app', 'door')),
    account_id    uuid        REFERENCES accounts (id) ON DELETE CASCADE,
    door_role_id  uuid        REFERENCES event_roles (id) ON DELETE CASCADE,
    expires_at    timestamptz NOT NULL,
    revoked_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK ((kind = 'app' AND account_id IS NOT NULL) OR (kind = 'door' AND door_role_id IS NOT NULL))
);

-- +goose Down
DROP TABLE sessions;
DROP TABLE payments;
DROP TABLE walk_in_requests;
DROP TABLE check_ins;
DROP TABLE messages;
DROP TABLE message_templates;
DROP TABLE invitations;
DROP TRIGGER guests_package_limit ON guests;
DROP FUNCTION enforce_package_limit();
DROP TABLE guests;
DROP TABLE event_roles;
DROP TABLE sections;
DROP TABLE events;
DROP TABLE otp_codes;
DROP TABLE accounts;

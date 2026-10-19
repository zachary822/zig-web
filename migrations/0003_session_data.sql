-- One schema change in each migration: MariaDB commits CREATE, ALTER
-- and DROP immediately, so a failure later in this file does not undo
-- the statements before it. This file has one ALTER TABLE statement, which
-- MariaDB applies completely or not at all.

-- Session data (see src/session.zig): sessions also for visitors who are
-- not logged in (user_id NULL), a JSON object with the data of the session,
-- the time of the last activity (visitor sessions expire 14 days after it),
-- and an index for the deletion of expired sessions.
ALTER TABLE session
    MODIFY user_id BIGINT UNSIGNED NULL,
    ADD data JSON NOT NULL DEFAULT '{}',
    ADD last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ADD KEY session_expires_at (expires_at);

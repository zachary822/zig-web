-- One schema change in each migration: MariaDB commits CREATE, ALTER
-- and DROP immediately, so a failure later in this file does not undo
-- the statements before it.

-- A login session (see src/session.zig). The cookie holds a random token;
-- token_hash is its SHA-256, so a copy of this table does not give valid
-- cookies. Logout deletes the row. Deleting a user deletes the user's
-- sessions.
CREATE TABLE session (
    token_hash BINARY(32) NOT NULL PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    KEY session_user_id (user_id),
    CONSTRAINT session_user FOREIGN KEY (user_id) REFERENCES `user` (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_general_ci;

-- One schema change in each migration: MariaDB commits CREATE, ALTER
-- and DROP immediately, so a failure later in this file does not undo
-- the statements before it.

-- `user` is also the name of a MariaDB function, so always quote it.
-- username and email are unique without regard to case (utf8mb4_general_ci).
-- password_hash holds an Argon2id PHC string (see src/password.zig).
CREATE TABLE `user` (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(64) NOT NULL,
    email VARCHAR(254) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY user_username (username),
    UNIQUE KEY user_email (email)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_general_ci;

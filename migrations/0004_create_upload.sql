-- One schema change in each migration: MariaDB commits CREATE, ALTER
-- and DROP immediately, so a failure later in this file does not undo
-- the statements before it.

-- A file in the uploads library (see src/library.zig). The file is
-- MEDIA_DIR/name, a random name with the extension of its type. kind is the
-- name of a `library.Kind` (for example `image`), and metadata holds what the
-- kind knows about the file, as JSON (for an image: width and height).
-- original_name is the name of the file on the computer of the user, only
-- to show it. size is in bytes, after the processing (for example, without
-- the metadata of a photo). A user with uploads cannot be deleted
-- (ON DELETE RESTRICT): the files must be deleted too.
CREATE TABLE upload (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED NOT NULL,
    kind VARCHAR(32) NOT NULL,
    name VARCHAR(64) NOT NULL,
    original_name VARCHAR(255) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    size INT UNSIGNED NOT NULL,
    metadata JSON NOT NULL DEFAULT '{}',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY upload_name (name),
    KEY upload_user_kind (user_id, kind),
    CONSTRAINT upload_user FOREIGN KEY (user_id) REFERENCES `user` (id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_general_ci;

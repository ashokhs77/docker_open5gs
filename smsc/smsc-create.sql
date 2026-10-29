CREATE TABLE `messages` (
    `id` INT(10) UNSIGNED AUTO_INCREMENT PRIMARY KEY NOT NULL,
    `caller` VARCHAR(255) NOT NULL,
    `callee` VARCHAR(255) NOT NULL,
    `text` VARCHAR(512),
    `dcs` INT(1),
    `valid` datetime NOT NULL,
    `srr` TINYINT(1) NOT NULL DEFAULT 0,
    `orig_mr` INT NOT NULL DEFAULT 0
);

INSERT INTO version (table_name, table_version) values ('messages','1');

-- Delivery-report support: survives past the `messages` row being deleted
-- on the SIP 200 OK to the MT MESSAGE, which happens before the terminating
-- UE's RP-ACK (the real delivery confirmation) arrives as its own transaction.
CREATE TABLE IF NOT EXISTS `pending_reports` (
    `id`           INT PRIMARY KEY,
    `caller`       VARCHAR(20) NOT NULL,
    `callee`       VARCHAR(20) NOT NULL,
    `orig_mr`      INT NOT NULL,
    `submitted_at` DATETIME NOT NULL,
    `created_at`   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS `pending_ue` (
    `callee` VARCHAR(64) NOT NULL,
    UNIQUE KEY `unique_callee` (`callee`)
);

CREATE TABLE `subscribed_ue` (
    `callee`         VARCHAR(64)  NOT NULL,
    `uri`            VARCHAR(255) NOT NULL,
    `subscribed_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`callee`)
);







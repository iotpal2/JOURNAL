-- Journals
CREATE TABLE ADMJOURNAL (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);

-- Journal entries (number is sequential per journal)
CREATE TABLE JOURNALENTRY (
    id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    journal_id INT NOT NULL,
    number     INT NOT NULL,
    entry_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    username   VARCHAR(50) NOT NULL,
    entry      VARCHAR(1000) NOT NULL,
    CONSTRAINT fk_journal FOREIGN KEY (journal_id)
        REFERENCES ADMJOURNAL(id) ON DELETE CASCADE,
    CONSTRAINT uk_journal_number UNIQUE (journal_id, number)
);

-- Permissions (who can edit a journal)
CREATE TABLE JOURNALPERMISSION (
    username   VARCHAR(50) NOT NULL,
    journal_id INT NOT NULL,
    PRIMARY KEY (username, journal_id),
    CONSTRAINT fk_perm_journal FOREIGN KEY (journal_id)
        REFERENCES ADMJOURNAL(id) ON DELETE CASCADE
);

-- Audit history (stores a snapshot of the entry after each action)
CREATE TABLE JOURNALHISTORY (
    history_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_id        INT NOT NULL,
    action          VARCHAR(10) NOT NULL,    -- 'INSERT', 'UPDATE', 'DELETE'
    change_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    changed_by      VARCHAR(50) NOT NULL,
    -- snapshot of the entry after the change (for DELETE it is the deleted row)
    journal_id      INT NOT NULL,
    number          INT NOT NULL,
    entry_date      TIMESTAMP,
    entry           VARCHAR(1000),
    CONSTRAINT fk_history_entry FOREIGN KEY (entry_id)
        REFERENCES JOURNALENTRY(id) ON DELETE CASCADE
);


#### a) Create Journal Entry
CREATE OR REPLACE PROCEDURE CREATE_JOURNAL_ENTRY (
    IN p_journal_id INT,
    IN p_entry      VARCHAR(1000),
    IN p_username   VARCHAR(50) DEFAULT CURRENT_USER
)
LANGUAGE SQL
BEGIN
    DECLARE v_next_num INT;
    DECLARE v_entry_id INT;

    -- Get the next sequential number for this journal
    SELECT COALESCE(MAX(number), 0) + 1
    INTO   v_next_num
    FROM   JOURNALENTRY
    WHERE  journal_id = p_journal_id;

    -- Insert the new entry
    INSERT INTO JOURNALENTRY (journal_id, number, entry_date, username, entry)
    VALUES (p_journal_id, v_next_num, CURRENT_TIMESTAMP, p_username, p_entry);

    -- Retrieve the generated entry ID
    VALUES IDENTITY_VAL_LOCAL() INTO v_entry_id;

    -- Log the insertion into history (snapshot of the new entry)
    INSERT INTO JOURNALHISTORY (entry_id, action, changed_by,
                                journal_id, number, entry_date, entry)
    VALUES (v_entry_id, 'INSERT', p_username,
            p_journal_id, v_next_num, CURRENT_TIMESTAMP, p_entry);
END;

b) Edit Journal Entry (with permission check)

CREATE OR REPLACE PROCEDURE EDIT_JOURNAL_ENTRY (
    IN p_journal_id   INT,
    IN p_number       INT,
    IN p_new_entry    VARCHAR(1000),
    IN p_username     VARCHAR(50) DEFAULT CURRENT_USER
)
LANGUAGE SQL
BEGIN
    DECLARE v_count INT;
    DECLARE v_entry_id INT;
    DECLARE v_old_entry VARCHAR(1000);
    DECLARE v_entry_date TIMESTAMP;

    -- 1. Check permission for the user on this journal
    SELECT COUNT(*)
    INTO   v_count
    FROM   JOURNALPERMISSION
    WHERE  journal_id = p_journal_id
      AND  username   = p_username;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'User does not have permission to edit this journal';
    END IF;

    -- 2. Retrieve current data (to log the old state, if desired) and the entry_id
    --    We will update and then log the new state; we also capture entry_id.
    SELECT id, entry, entry_date
    INTO   v_entry_id, v_old_entry, v_entry_date
    FROM   JOURNALENTRY
    WHERE  journal_id = p_journal_id
      AND  number     = p_number;

    -- If no row found, the above SELECT will raise SQLSTATE '02000'.
    -- We can handle it gracefully:
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Entry not found for the given journal and number';
    END IF;

    -- 3. Perform the update (also refresh the timestamp)
    UPDATE JOURNALENTRY
    SET    entry      = p_new_entry,
           entry_date = CURRENT_TIMESTAMP
    WHERE  journal_id = p_journal_id
      AND  number     = p_number;

    -- 4. Log the change in history (store the new state)
    INSERT INTO JOURNALHISTORY (entry_id, action, changed_by,
                                journal_id, number, entry_date, entry)
    VALUES (v_entry_id, 'UPDATE', p_username,
            p_journal_id, p_number, CURRENT_TIMESTAMP, p_new_entry);
END;

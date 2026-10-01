-- =============================================================================
--  WBS Resource Manager - database schema (template)
--  Target: PostgreSQL 13 or later
--
--  One database for every academic year. Year-scoped data carries an
--  academic_year_id; people, departments, modules and courses persist across
--  years. Replaces the old one-database-per-year model (wbsrmadmin_rm2526,
--  wbsrmadmin_rm2627, ...) and the manual rollover steps in the Resourcing
--  Lead manual.
--
--  Run on an EMPTY database:
--      createdb wbs_rm
--      psql -d wbs_rm -v ON_ERROR_STOP=1 -f wbs_resource_manager_schema.sql
--
--  The whole script runs in one transaction: it either builds everything or
--  nothing.
--
--  Sections
--    1. Utilities
--    2. Academic years
--    3. Departments and staff
--    4. Accounts and authentication
--    5. Credit categories (extensible)
--    6. Courses, modules, occurrences
--    7. Activities, credit ledger, timetabled sessions
--    8. Publishing
--    9. Audit trail
--   10. Copy an academic year forward
--   11. Reporting views (replace Ad Hoc Queries)
--   12. Seed data
--   13. First-Owner bootstrap
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. UTILITIES
-- =============================================================================

-- Keeps updated_at current on every table that has one (wired up in section 12).
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;


-- =============================================================================
-- 2. ACADEMIC YEARS
-- =============================================================================
-- status replaces the NEXTYEARFLAG constant that used to be hand-edited in
-- headerHtml.php: 'planning' = show the "NEXT ACADEMIC YEAR" banner.

CREATE TABLE academic_year (
    id                   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                 text NOT NULL UNIQUE CHECK (code ~ '^[0-9]{4}-[0-9]{2}$'),  -- '2026-27'
    start_date           date NOT NULL,
    end_date             date NOT NULL,
    status               text NOT NULL DEFAULT 'planning'
                         CHECK (status IN ('planning', 'current', 'archived')),
    copied_from_year_id  integer REFERENCES academic_year (id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (end_date > start_date)
);

-- At most one year can be 'current' at a time.
CREATE UNIQUE INDEX academic_year_one_current
    ON academic_year ((true)) WHERE status = 'current';

-- Deleting a year cascades to everything in it, so only allow deleting a
-- year that is still in planning (e.g. one created by mistake).
CREATE FUNCTION protect_academic_year_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'planning' THEN
        RAISE EXCEPTION 'Academic year % is %; only planning years can be deleted',
            OLD.code, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER academic_year_protect_delete
    BEFORE DELETE ON academic_year
    FOR EACH ROW EXECUTE FUNCTION protect_academic_year_delete();


-- =============================================================================
-- 3. DEPARTMENTS AND STAFF
-- =============================================================================

-- Old table: staff_group. is_subject_group separates real departments from
-- non-department groups (HPL / sessional, SMT, Other).
CREATE TABLE staff_group (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code              text NOT NULL UNIQUE,           -- 'COMP'; used in published page paths
    name              text NOT NULL,
    is_subject_group  boolean NOT NULL DEFAULT true,
    leader_staff_id   integer,                        -- FK added after staff exists
    is_active         boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- A person. Identity only - nothing here changes from year to year.
-- Web codes are deliberately absent: real login replaces them.
CREATE TABLE staff (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_number  text UNIQUE,                        -- HR / payroll number, optional
    staff_code    text NOT NULL,                      -- the 5-character staff ID, e.g. 'smij1': usually 3 letters
                                                      -- of surname + first letter of forename + a digit.
                                                      -- Same value as staff_id in the old system, so people
                                                      -- match across the old yearly databases. Default sort order.
    forename      text NOT NULL,
    surname       text NOT NULL,
    email         text,                               -- the login username; someone without one
                                                      -- can't be invited to sign in until it's added
    is_active     boolean NOT NULL DEFAULT true,      -- leavers: deactivate, don't delete
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CHECK (staff_code ~ '^[A-Za-z0-9]{5}$')
);

CREATE UNIQUE INDEX staff_email_unique ON staff (lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX staff_code_unique  ON staff (lower(staff_code));

ALTER TABLE staff_group
    ADD CONSTRAINT staff_group_leader_fk
    FOREIGN KEY (leader_staff_id) REFERENCES staff (id) ON DELETE SET NULL;

-- Contract statuses (old table: staff_status). A lookup rather than a fixed
-- list so new statuses can be added without a schema change.
CREATE TABLE contract_status (
    code           text PRIMARY KEY,                  -- 'FT', 'PT', 'HPL', 'NEW', 'TBA'...
    description    text NOT NULL,
    is_sessional   boolean NOT NULL DEFAULT false,    -- true for HPL: hidden names show 'HPL' not 'TBC'
    display_order  integer NOT NULL DEFAULT 100
);

-- A person's details for one academic year. A staff member must have a row
-- here to be allocated work in that year.
-- staff_group_id is the single "Subject Group" field on Staff Details - there
-- is no separate home-department / secondary-group pair.
CREATE TABLE staff_year (
    staff_id          integer NOT NULL REFERENCES staff (id) ON DELETE RESTRICT,
    academic_year_id  integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    staff_group_id    integer NOT NULL REFERENCES staff_group (id) ON DELETE RESTRICT,
    contract_type     text NOT NULL DEFAULT 'FT' REFERENCES contract_status (code),
    fte               numeric(4,3) NOT NULL DEFAULT 1.000 CHECK (fte >= 0 AND fte <= 1.5),
    target_credits    numeric(7,2) CHECK (target_credits >= 0),
    room              text,
    phone             text,
    -- Publish/Hide: whether OTHER staff see this person's real name when they
    -- expand a module on their own timetable. Hidden shows 'TBC' ('HPL' for
    -- sessional staff). Never affects what Owner / Head / PAS Admin see.
    publish_name      boolean NOT NULL DEFAULT true,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (staff_id, academic_year_id)
);

-- Delete Group is blocked while any staff are assigned: enforced by the
-- ON DELETE RESTRICT above.
CREATE INDEX staff_year_group_idx ON staff_year (academic_year_id, staff_group_id);

-- Additional group memberships (old table: membership). staff_year.staff_group_id
-- is a person's MAIN group (it decides who publishes their timetable and which
-- department a Head belongs to); they can also belong to other groups, for
-- example a Head of School who is in their department and in SMT.
-- Group totals count main members only, so nobody's credits are counted twice.
CREATE TABLE staff_year_group (
    staff_id          integer NOT NULL,
    academic_year_id  integer NOT NULL,
    staff_group_id    integer NOT NULL REFERENCES staff_group (id) ON DELETE RESTRICT,
    PRIMARY KEY (staff_id, academic_year_id, staff_group_id),
    FOREIGN KEY (staff_id, academic_year_id)
        REFERENCES staff_year (staff_id, academic_year_id) ON DELETE CASCADE
);

CREATE INDEX staff_year_group_member_idx ON staff_year_group (academic_year_id, staff_group_id);

-- An additional membership can't repeat the person's main group ...
CREATE FUNCTION check_additional_group() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM staff_year
                WHERE staff_id = NEW.staff_id AND academic_year_id = NEW.academic_year_id
                  AND staff_group_id = NEW.staff_group_id) THEN
        RAISE EXCEPTION 'That group is already this person''s main group'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER staff_year_group_check
    BEFORE INSERT OR UPDATE ON staff_year_group
    FOR EACH ROW EXECUTE FUNCTION check_additional_group();

-- ... and when someone's main group changes to one they were an additional
-- member of, that additional membership is dropped.
CREATE FUNCTION tidy_additional_groups() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM staff_year_group
     WHERE staff_id = NEW.staff_id AND academic_year_id = NEW.academic_year_id
       AND staff_group_id = NEW.staff_group_id;
    RETURN NEW;
END $$;

CREATE TRIGGER staff_year_main_group_changed
    AFTER UPDATE OF staff_group_id ON staff_year
    FOR EACH ROW EXECUTE FUNCTION tidy_additional_groups();


-- =============================================================================
-- 4. ACCOUNTS AND AUTHENTICATION
-- =============================================================================
-- Username = staff.email. Exactly four roles. A Head's department scope is
-- their own staff_year.staff_group_id for the year being viewed.
-- Role checks and scoping are enforced by the application server; the
-- database enforces the rules that must never be broken (last Owner, etc.).

CREATE TABLE user_account (
    id                   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_id             integer NOT NULL UNIQUE REFERENCES staff (id) ON DELETE CASCADE,
    system_role          text NOT NULL DEFAULT 'staff'
                         CHECK (system_role IN ('owner', 'head', 'pas_admin', 'staff')),
    -- Full argon2id / bcrypt hash string (includes its own salt). NULL until
    -- the person accepts their invite. Nobody ever sets another person's password.
    password_hash        text,
    is_active            boolean NOT NULL DEFAULT true,
    failed_login_count   integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
    locked_until         timestamptz,
    last_login_at        timestamptz,
    password_changed_at  timestamptz,
    -- Light / dark display preference, saved to the account so it follows
    -- the person to any device. NULL = follow the device's own setting.
    theme_preference     text CHECK (theme_preference IN ('light', 'dark')),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

-- Every staff member automatically gets an account with the basic 'staff'
-- role (read-only view of their own timetable).
CREATE FUNCTION create_account_for_new_staff() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO user_account (staff_id) VALUES (NEW.id);
    RETURN NEW;
END $$;

CREATE TRIGGER staff_create_account
    AFTER INSERT ON staff
    FOR EACH ROW EXECUTE FUNCTION create_account_for_new_staff();

-- Last-Owner safeguard: the final active Owner can never be demoted,
-- deactivated or deleted. Locking the Owner rows means two Owners demoting
-- each other at the same moment deadlock (one is rolled back) instead of
-- both succeeding.
CREATE FUNCTION protect_last_owner() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.system_role = 'owner' AND OLD.is_active
       AND (TG_OP = 'DELETE' OR NEW.system_role <> 'owner' OR NOT NEW.is_active) THEN

        PERFORM 1 FROM user_account
         WHERE system_role = 'owner' AND is_active
           FOR UPDATE;

        IF NOT EXISTS (SELECT 1 FROM user_account
                        WHERE system_role = 'owner' AND is_active AND id <> OLD.id) THEN
            RAISE EXCEPTION 'Cannot remove the last active Owner - make someone else an Owner first'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER user_account_protect_last_owner
    BEFORE UPDATE OF system_role, is_active OR DELETE ON user_account
    FOR EACH ROW EXECUTE FUNCTION protect_last_owner();

-- One-time invite and password-reset links. Only a SHA-256 hash of the token
-- is stored; the raw token exists only in the email.
-- Queueing: the app inserts a row with token_hash NULL; the mailer job
-- generates the token, stores its hash, sends the email, sets email_sent_at.
CREATE TABLE auth_token (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_account_id     integer NOT NULL REFERENCES user_account (id) ON DELETE CASCADE,
    purpose             text NOT NULL CHECK (purpose IN ('invite', 'password_reset')),
    token_hash          text UNIQUE,
    expires_at          timestamptz NOT NULL DEFAULT now() + interval '7 days',
    email_sent_at       timestamptz,
    used_at             timestamptz,
    created_by_user_id  integer REFERENCES user_account (id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX auth_token_unsent_idx ON auth_token (created_at) WHERE email_sent_at IS NULL;

-- Login attempts, for rate limiting and security review.
CREATE TABLE login_attempt (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         text NOT NULL,
    ip_address    inet,
    succeeded     boolean NOT NULL,
    attempted_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX login_attempt_email_idx ON login_attempt (lower(email), attempted_at DESC);
CREATE INDEX login_attempt_ip_idx    ON login_attempt (ip_address, attempted_at DESC);

-- Web login sessions, in the format used by the connect-pg-simple package for
-- Express. Named http_session so it can't be confused with timetabled
-- teaching sessions - configure the package with tableName: 'http_session'.
CREATE TABLE http_session (
    sid     varchar NOT NULL PRIMARY KEY,
    sess    json NOT NULL,
    expire  timestamp(6) NOT NULL
);

CREATE INDEX http_session_expire_idx ON http_session (expire);


-- =============================================================================
-- 5. CREDIT CATEGORIES (old table: role_type)
-- =============================================================================
-- Extensible: adding a row here is the "Add Credit Category" action.
--   applies_to = 'teaching'      -> a budget line on every module occurrence
--                                   (Semester 1, Semester 2, Supervision,
--                                   Module Leader, Moderation, Major Changes)
--   applies_to = 'non_teaching'  -> a grouping for named duties
--                                   (e.g. Management - Programmes)
-- semester is set for Semester 1 / 2 / 3 so totals split by semester. The
-- Owner adds, renames and deletes these as "time slots" in the app.
-- is_timetabled marks categories that carry timetabled sessions.

CREATE TABLE credit_category (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE,
    name           text NOT NULL,
    applies_to     text NOT NULL CHECK (applies_to IN ('teaching', 'non_teaching')),
    legacy_code    text,                              -- old time_slot.taught_in or role_type.type_code
    is_management  boolean NOT NULL DEFAULT false,
    is_timetabled  boolean NOT NULL DEFAULT false,
    semester       smallint CHECK (semester BETWEEN 1 AND 9),   -- Semester 1, 2, 3...; totals split by it
    sort_order     integer NOT NULL DEFAULT 100,
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, applies_to),     -- lets child tables require the right kind
    CHECK (semester IS NULL OR applies_to = 'teaching'),
    CHECK (NOT is_timetabled OR applies_to = 'teaching')
);


-- =============================================================================
-- 6. COURSES, MODULES, OCCURRENCES
-- =============================================================================

CREATE TABLE course (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text NOT NULL UNIQUE,            -- also the Course Information Site path
    title            text NOT NULL,
    level            text NOT NULL CHECK (level IN ('UG', 'PG')),
    duration_years   smallint NOT NULL CHECK (duration_years BETWEEN 1 AND 7),
    staff_group_id   integer REFERENCES staff_group (id) ON DELETE RESTRICT,
    leader_staff_id  integer REFERENCES staff (id) ON DELETE SET NULL,
    show_on_cis      boolean NOT NULL DEFAULT true,   -- listed on the Course Information Site
    subject          text,                            -- old course.subject
    is_corporate     boolean NOT NULL DEFAULT false,  -- old course.corporate
    display_order    smallint,                        -- order on menus and the CIS
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Identity of a module. Staff from ANY department can be allocated to it.
CREATE TABLE module (
    id                     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                   text NOT NULL UNIQUE,
    title                  text NOT NULL,
    owning_staff_group_id  integer NOT NULL REFERENCES staff_group (id) ON DELETE RESTRICT,
    academic_credits       smallint CHECK (academic_credits IN (0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 60, 120, 240)),  -- not workload; 0 = no credit weighting
    subject                text,                                    -- old module.subject
    level                  smallint CHECK (level BETWEEN 3 AND 8),
    is_active              boolean NOT NULL DEFAULT true,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now()
);

-- One run of a module in one academic year (Occ. A, B, ...).
-- Delete Module is blocked while occurrences exist (ON DELETE RESTRICT).
CREATE TABLE occurrence (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module_id         integer NOT NULL REFERENCES module (id) ON DELETE RESTRICT,
    academic_year_id  integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    occ_code          text NOT NULL CHECK (occ_code ~ '^[A-Z0-9]{1,3}$'),  -- typed, e.g. A Business, C Computing,
                                                                          -- D Accounting & Finance, H Health
    description       text,                           -- campus, mode, cohort...
    no_of_groups      numeric(5,2) NOT NULL DEFAULT 1 CHECK (no_of_groups > 0),  -- old occurrence.no_of_groups
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (module_id, academic_year_id, occ_code),
    UNIQUE (id, academic_year_id)
);

-- Which courses an occurrence belongs to (drives the course timetables).
CREATE TABLE course_occurrence (
    course_id      integer NOT NULL REFERENCES course (id) ON DELETE RESTRICT,
    occurrence_id  integer NOT NULL REFERENCES occurrence (id) ON DELETE CASCADE,
    year_of_study  smallint CHECK (year_of_study BETWEEN 1 AND 7),
    is_core        boolean,                           -- old course_module.mandatory_flag
    is_primary     boolean NOT NULL DEFAULT false,    -- old course_module.primary_flag
    PRIMARY KEY (course_id, occurrence_id)
);

CREATE INDEX course_occurrence_occ_idx ON course_occurrence (occurrence_id);


-- =============================================================================
-- 7. ACTIVITIES, CREDIT LEDGER, TIMETABLED SESSIONS
-- =============================================================================
-- activity is the shared parent of both kinds of work, so a single ledger
-- (activity_allocation) holds every credit a person is given.

CREATE TABLE activity (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    academic_year_id  integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    kind              text NOT NULL CHECK (kind IN ('teaching', 'non_teaching')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, academic_year_id),
    UNIQUE (id, academic_year_id, kind)
);

-- A credit-category budget line on one occurrence, e.g. "BUS1001 Occ A,
-- Semester 1, 120 credits". budget_credits is the total set on Module Details
-- (Owner only); Module Allocation divides it between staff.
CREATE TABLE teaching_role (
    activity_id          integer PRIMARY KEY,
    academic_year_id     integer NOT NULL,
    kind                 text NOT NULL DEFAULT 'teaching' CHECK (kind = 'teaching'),
    occurrence_id        integer NOT NULL,
    credit_category_id   integer NOT NULL,
    category_applies_to  text NOT NULL DEFAULT 'teaching' CHECK (category_applies_to = 'teaching'),
    budget_credits       numeric(7,2) NOT NULL DEFAULT 0 CHECK (budget_credits >= 0),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (activity_id, academic_year_id, kind)
        REFERENCES activity (id, academic_year_id, kind) ON DELETE CASCADE,
    FOREIGN KEY (occurrence_id, academic_year_id)
        REFERENCES occurrence (id, academic_year_id) ON DELETE CASCADE,
    FOREIGN KEY (credit_category_id, category_applies_to)
        REFERENCES credit_category (id, applies_to),
    UNIQUE (occurrence_id, credit_category_id)
);

-- A named duty, e.g. "Course Leader - BSc Software Development".
CREATE TABLE non_teaching_role (
    activity_id          integer PRIMARY KEY,
    academic_year_id     integer NOT NULL,
    kind                 text NOT NULL DEFAULT 'non_teaching' CHECK (kind = 'non_teaching'),
    credit_category_id   integer NOT NULL,
    category_applies_to  text NOT NULL DEFAULT 'non_teaching' CHECK (category_applies_to = 'non_teaching'),
    name                 text NOT NULL,
    description          text,
    staff_group_id       integer REFERENCES staff_group (id) ON DELETE SET NULL,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (activity_id, academic_year_id, kind)
        REFERENCES activity (id, academic_year_id, kind) ON DELETE CASCADE,
    FOREIGN KEY (credit_category_id, category_applies_to)
        REFERENCES credit_category (id, applies_to),
    UNIQUE (academic_year_id, credit_category_id, name)
);

-- When a role row goes (e.g. its occurrence is deleted), remove its parent
-- activity too so no orphans are left.
CREATE FUNCTION delete_parent_activity() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM activity WHERE id = OLD.activity_id;
    RETURN OLD;
END $$;

CREATE TRIGGER teaching_role_cleanup
    AFTER DELETE ON teaching_role
    FOR EACH ROW EXECUTE FUNCTION delete_parent_activity();

CREATE TRIGGER non_teaching_role_cleanup
    AFTER DELETE ON non_teaching_role
    FOR EACH ROW EXECUTE FUNCTION delete_parent_activity();

-- The credit ledger: staff x activity -> credits. Also records Module Leader
-- and Moderator (as allocations in those categories), so there is a single
-- source of truth for who does what.
-- The composite FKs guarantee the person has a staff_year row in the SAME
-- year as the activity.
CREATE TABLE activity_allocation (
    activity_id       integer NOT NULL,
    staff_id          integer NOT NULL,
    academic_year_id  integer NOT NULL,
    credits           numeric(7,2) NOT NULL DEFAULT 0 CHECK (credits >= 0),
    note              text,                            -- e.g. '0.34 FTE', 'Shared'
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (activity_id, staff_id),
    FOREIGN KEY (activity_id, academic_year_id)
        REFERENCES activity (id, academic_year_id) ON DELETE CASCADE,
    FOREIGN KEY (staff_id, academic_year_id)
        REFERENCES staff_year (staff_id, academic_year_id)   -- NO ACTION: blocks removing a
                                                             -- person's year while they hold credits
);

CREATE INDEX activity_allocation_staff_idx ON activity_allocation (staff_id, academic_year_id);

-- Timetabled slots (Module Sessions tab). Every member of staff allocated to
-- the teaching role sees these sessions on their timetable.
CREATE TABLE teaching_session (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    teaching_role_id  integer NOT NULL REFERENCES teaching_role (activity_id) ON DELETE CASCADE,
    day_of_week       smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),  -- 1 = Monday
    start_time        time NOT NULL,                  -- day runs 09:15 to 21:15 in hourly blocks
    end_time          time NOT NULL,
    room              text,
    session_type      text,                           -- Lecture, Seminar, Workshop...
    weeks             text,                           -- e.g. '1-12'
    comment           text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);

CREATE INDEX teaching_session_role_idx ON teaching_session (teaching_role_id);

CREATE FUNCTION check_session_category() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1
                     FROM teaching_role tr
                     JOIN credit_category c ON c.id = tr.credit_category_id
                    WHERE tr.activity_id = NEW.teaching_role_id
                      AND c.is_timetabled) THEN
        RAISE EXCEPTION 'Sessions can only be added to a timetabled category (e.g. Semester 1 or Semester 2)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER teaching_session_check_category
    BEFORE INSERT OR UPDATE OF teaching_role_id ON teaching_session
    FOR EACH ROW EXECUTE FUNCTION check_session_category();

-- ---- Helpers for creating roles ------------------------------------------

-- Creates one teaching-role budget line (activity + teaching_role) unless it
-- already exists. Returns the new activity id, or NULL if it already existed.
CREATE FUNCTION create_teaching_role(p_occurrence_id integer,
                                     p_category_id   integer,
                                     p_budget        numeric DEFAULT 0)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_year     integer;
    v_activity integer;
BEGIN
    IF EXISTS (SELECT 1 FROM teaching_role
                WHERE occurrence_id = p_occurrence_id
                  AND credit_category_id = p_category_id) THEN
        RETURN NULL;
    END IF;

    SELECT academic_year_id INTO STRICT v_year FROM occurrence WHERE id = p_occurrence_id;

    INSERT INTO activity (academic_year_id, kind)
    VALUES (v_year, 'teaching')
    RETURNING id INTO v_activity;

    INSERT INTO teaching_role (activity_id, academic_year_id, occurrence_id,
                               credit_category_id, budget_credits)
    VALUES (v_activity, v_year, p_occurrence_id, p_category_id, p_budget);

    RETURN v_activity;
END $$;

-- Creates a named non-teaching duty. Returns its activity id.
CREATE FUNCTION create_non_teaching_role(p_academic_year_id integer,
                                         p_category_id      integer,
                                         p_name             text,
                                         p_staff_group_id   integer DEFAULT NULL,
                                         p_description      text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_activity integer;
BEGIN
    INSERT INTO activity (academic_year_id, kind)
    VALUES (p_academic_year_id, 'non_teaching')
    RETURNING id INTO v_activity;

    INSERT INTO non_teaching_role (activity_id, academic_year_id, credit_category_id,
                                   name, description, staff_group_id)
    VALUES (v_activity, p_academic_year_id, p_category_id,
            p_name, p_description, p_staff_group_id);

    RETURN v_activity;
END $$;

-- A new occurrence automatically gets a 0-credit budget line for every
-- active teaching category.
CREATE FUNCTION occurrence_add_teaching_roles() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM create_teaching_role(NEW.id, c.id)
       FROM credit_category c
      WHERE c.applies_to = 'teaching' AND c.is_active;
    RETURN NEW;
END $$;

CREATE TRIGGER occurrence_create_roles
    AFTER INSERT ON occurrence
    FOR EACH ROW EXECUTE FUNCTION occurrence_add_teaching_roles();

-- "Add Credit Category": a new teaching category is back-filled onto every
-- occurrence in every non-archived year, at 0 credits.
CREATE FUNCTION category_backfill_teaching_roles() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM create_teaching_role(o.id, NEW.id)
       FROM occurrence o
       JOIN academic_year y ON y.id = o.academic_year_id
      WHERE y.status <> 'archived';
    RETURN NEW;
END $$;

CREATE TRIGGER credit_category_backfill
    AFTER INSERT ON credit_category
    FOR EACH ROW
    WHEN (NEW.applies_to = 'teaching' AND NEW.is_active)
    EXECUTE FUNCTION category_backfill_teaching_roles();


-- =============================================================================
-- 8. PUBLISHING
-- =============================================================================
-- Heads and the Owner edit freely; staff only see what has been published.
-- On publish, the app builds a snapshot (JSON) of each affected staff
-- timetable and course timetable. These replace the generated .html files
-- under RMOutput/, so no folders need creating by hand in Plesk.

CREATE TABLE publication (
    id                    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    academic_year_id      integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    staff_group_id        integer REFERENCES staff_group (id) ON DELETE SET NULL,  -- NULL = all departments
    published_by_user_id  integer REFERENCES user_account (id) ON DELETE SET NULL,
    published_at          timestamptz NOT NULL DEFAULT now(),
    note                  text
);

CREATE INDEX publication_lookup_idx ON publication (academic_year_id, staff_group_id, published_at DESC);

CREATE TABLE published_staff_timetable (
    academic_year_id  integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    staff_id          integer NOT NULL REFERENCES staff (id) ON DELETE CASCADE,
    publication_id    integer NOT NULL REFERENCES publication (id) ON DELETE CASCADE,
    content           jsonb NOT NULL,
    PRIMARY KEY (academic_year_id, staff_id)
);

CREATE TABLE published_course_timetable (
    academic_year_id  integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    course_id         integer NOT NULL REFERENCES course (id) ON DELETE CASCADE,
    publication_id    integer NOT NULL REFERENCES publication (id) ON DELETE CASCADE,
    content           jsonb NOT NULL,
    PRIMARY KEY (academic_year_id, course_id)
);


-- Overview "needs attention" overrides. Each item the app flags (staff over
-- target, over/under-allocated module, missing leader or moderator, timetable
-- clash) has a stable issue_key, e.g. 'over:<staff>' or
-- 'clash:<staff>|<activity>|<activity>', and a fingerprint of the numbers behind
-- it (totals, budgets, session times). An override hides the item only while the
-- current fingerprint still matches the saved one; any change to that item
-- brings it back. Overrides belong to one academic year and aren't copied forward.
CREATE TABLE issue_override (
    academic_year_id    integer NOT NULL REFERENCES academic_year (id) ON DELETE CASCADE,
    issue_key           text NOT NULL,
    fingerprint         text NOT NULL,
    note                text CHECK (char_length(note) <= 200),
    overridden_by_user_id integer REFERENCES user_account (id) ON DELETE SET NULL,
    overridden_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (academic_year_id, issue_key)
);

-- =============================================================================
-- 9. AUDIT TRAIL
-- =============================================================================
-- Every create / update / delete / publish / role change is written here by
-- the app, replacing the prototype's browser confirm() pop-ups. It also
-- supplies the "unpublished changes" count on Publish Details (rows since the
-- last publication for that department). Treat as append-only - see the
-- permissions note at the end of the file.

CREATE TABLE audit_log (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at       timestamptz NOT NULL DEFAULT now(),
    user_account_id   integer REFERENCES user_account (id) ON DELETE SET NULL,
    academic_year_id  integer REFERENCES academic_year (id) ON DELETE SET NULL,
    staff_group_id    integer REFERENCES staff_group (id) ON DELETE SET NULL,
    action            text NOT NULL,     -- 'create', 'update', 'delete', 'publish', 'role_change', ...
    entity_type       text NOT NULL,     -- 'staff', 'module', 'activity_allocation', ...
    entity_id         text,
    before_data       jsonb,
    after_data        jsonb
);

CREATE INDEX audit_log_year_idx   ON audit_log (academic_year_id, staff_group_id, occurred_at DESC);
CREATE INDEX audit_log_entity_idx ON audit_log (entity_type, entity_id);


-- =============================================================================
-- 10. COPY AN ACADEMIC YEAR FORWARD
-- =============================================================================
-- Replaces the manual rollover (copy database, copy folders, edit
-- headerHtml.php / staff.php / course_menu.html, delete all sessions).
-- Creates the new year as 'planning' and copies forward: staff-year records
-- (active staff only), occurrences (active modules only), category budgets,
-- course links, non-teaching roles, and optionally allocations and sessions.
--
--   SELECT copy_academic_year(
--       (SELECT id FROM academic_year WHERE code = '2026-27'),
--       '2027-28', DATE '2027-09-01', DATE '2028-08-31');

CREATE FUNCTION copy_academic_year(p_from_year_id     integer,
                                   p_new_code         text,
                                   p_start_date       date,
                                   p_end_date         date,
                                   p_copy_allocations boolean DEFAULT true,
                                   p_copy_sessions    boolean DEFAULT true)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_new_year  integer;
    v_activity  integer;
    r           record;
BEGIN
    INSERT INTO academic_year (code, start_date, end_date, status, copied_from_year_id)
    VALUES (p_new_code, p_start_date, p_end_date, 'planning', p_from_year_id)
    RETURNING id INTO v_new_year;

    -- Staff for the year (leavers are skipped).
    INSERT INTO staff_year (staff_id, academic_year_id, staff_group_id, contract_type,
                            fte, target_credits, room, phone, publish_name, notes)
    SELECT sy.staff_id, v_new_year, sy.staff_group_id, sy.contract_type,
           sy.fte, sy.target_credits, sy.room, sy.phone, sy.publish_name, sy.notes
      FROM staff_year sy
      JOIN staff s ON s.id = sy.staff_id
     WHERE sy.academic_year_id = p_from_year_id
       AND s.is_active;

    -- Additional group memberships for the staff carried forward.
    INSERT INTO staff_year_group (staff_id, academic_year_id, staff_group_id)
    SELECT g.staff_id, v_new_year, g.staff_group_id
      FROM staff_year_group g
      JOIN staff_year sy ON sy.staff_id = g.staff_id AND sy.academic_year_id = v_new_year
     WHERE g.academic_year_id = p_from_year_id;

    -- Occurrences. The occurrence trigger creates their 0-credit budget lines.
    INSERT INTO occurrence (module_id, academic_year_id, occ_code, description, no_of_groups)
    SELECT o.module_id, v_new_year, o.occ_code, o.description, o.no_of_groups
      FROM occurrence o
      JOIN module m ON m.id = o.module_id
     WHERE o.academic_year_id = p_from_year_id
       AND m.is_active;

    -- Map each old teaching role to its new equivalent.
    DROP TABLE IF EXISTS pg_temp.role_map;
    CREATE TEMP TABLE role_map ON COMMIT DROP AS
    SELECT t_old.activity_id AS old_id,
           t_new.activity_id AS new_id
      FROM teaching_role t_old
      JOIN occurrence o_old ON o_old.id = t_old.occurrence_id
      JOIN occurrence o_new ON o_new.module_id = o_old.module_id
                           AND o_new.occ_code  = o_old.occ_code
                           AND o_new.academic_year_id = v_new_year
      JOIN teaching_role t_new ON t_new.occurrence_id = o_new.id
                              AND t_new.credit_category_id = t_old.credit_category_id
     WHERE t_old.academic_year_id = p_from_year_id;

    -- Category budgets.
    UPDATE teaching_role t_new
       SET budget_credits = t_old.budget_credits
      FROM role_map m
      JOIN teaching_role t_old ON t_old.activity_id = m.old_id
     WHERE t_new.activity_id = m.new_id;

    -- Course links.
    INSERT INTO course_occurrence (course_id, occurrence_id, year_of_study, is_core, is_primary)
    SELECT co.course_id, o_new.id, co.year_of_study, co.is_core, co.is_primary
      FROM course_occurrence co
      JOIN course c         ON c.id = co.course_id AND c.is_active
      JOIN occurrence o_old ON o_old.id = co.occurrence_id
      JOIN occurrence o_new ON o_new.module_id = o_old.module_id
                           AND o_new.occ_code  = o_old.occ_code
                           AND o_new.academic_year_id = v_new_year
     WHERE o_old.academic_year_id = p_from_year_id;

    -- Teaching allocations (only for staff carried into the new year).
    IF p_copy_allocations THEN
        INSERT INTO activity_allocation (activity_id, staff_id, academic_year_id, credits, note)
        SELECT m.new_id, aa.staff_id, v_new_year, aa.credits, aa.note
          FROM role_map m
          JOIN activity_allocation aa ON aa.activity_id = m.old_id
          JOIN staff_year sy ON sy.staff_id = aa.staff_id
                            AND sy.academic_year_id = v_new_year;
    END IF;

    -- Timetabled sessions.
    IF p_copy_sessions THEN
        INSERT INTO teaching_session (teaching_role_id, day_of_week, start_time, end_time,
                                      room, session_type, weeks, comment)
        SELECT m.new_id, ts.day_of_week, ts.start_time, ts.end_time,
               ts.room, ts.session_type, ts.weeks, ts.comment
          FROM role_map m
          JOIN teaching_session ts ON ts.teaching_role_id = m.old_id;
    END IF;

    -- Non-teaching roles, and optionally who holds them.
    FOR r IN
        SELECT ntr.*
          FROM non_teaching_role ntr
          JOIN credit_category c ON c.id = ntr.credit_category_id AND c.is_active
         WHERE ntr.academic_year_id = p_from_year_id
    LOOP
        v_activity := create_non_teaching_role(v_new_year, r.credit_category_id, r.name,
                                               r.staff_group_id, r.description);
        IF p_copy_allocations THEN
            INSERT INTO activity_allocation (activity_id, staff_id, academic_year_id, credits, note)
            SELECT v_activity, aa.staff_id, v_new_year, aa.credits, aa.note
              FROM activity_allocation aa
              JOIN staff_year sy ON sy.staff_id = aa.staff_id
                                AND sy.academic_year_id = v_new_year
             WHERE aa.activity_id = r.activity_id;
        END IF;
    END LOOP;

    DROP TABLE IF EXISTS pg_temp.role_map;
    RETURN v_new_year;
END $$;


-- =============================================================================
-- 11. REPORTING VIEWS (replace free-text Ad Hoc Queries)
-- =============================================================================
-- Fixed, read-only reports. The app filters these by role and department
-- before anything is sent to the browser.

-- Name as OTHER staff see it (Publish / Hide rule).
CREATE VIEW v_staff_public_name AS
SELECT sy.academic_year_id,
       sy.staff_id,
       CASE
           WHEN sy.publish_name          THEN s.forename || ' ' || s.surname
           WHEN cs.is_sessional          THEN 'HPL'
           ELSE 'TBC'
       END AS public_name
  FROM staff_year sy
  JOIN staff s ON s.id = sy.staff_id
  JOIN contract_status cs ON cs.code = sy.contract_type;

-- Every credit a person holds, one row per allocation, with its category.
CREATE VIEW v_allocation_detail AS
SELECT aa.academic_year_id,
       aa.staff_id,
       a.kind,
       aa.activity_id,
       c.id        AS credit_category_id,
       c.code      AS category_code,
       c.name      AS category_name,
       c.semester,
       c.is_management,
       m.code      AS module_code,
       o.occ_code,
       ntr.name    AS non_teaching_role_name,
       aa.credits,
       aa.note
  FROM activity_allocation aa
  JOIN activity a                ON a.id = aa.activity_id
  LEFT JOIN teaching_role tr     ON tr.activity_id = a.id
  LEFT JOIN occurrence o         ON o.id = tr.occurrence_id
  LEFT JOIN module m             ON m.id = o.module_id
  LEFT JOIN non_teaching_role ntr ON ntr.activity_id = a.id
  JOIN credit_category c         ON c.id = COALESCE(tr.credit_category_id, ntr.credit_category_id);

-- Staff totals against target, with teaching split into Semester 1 / 2
-- (Show Totals, and the "Credit totals" report).
CREATE VIEW v_staff_year_totals AS
SELECT sy.academic_year_id,
       sy.staff_id,
       s.staff_code,
       s.forename,
       s.surname,
       sy.staff_group_id,
       sy.contract_type,
       sy.fte,
       sy.target_credits,
       COALESCE(SUM(d.credits) FILTER (WHERE d.semester = 1), 0)                          AS semester_1,
       COALESCE(SUM(d.credits) FILTER (WHERE d.semester = 2), 0)                          AS semester_2,
       COALESCE(SUM(d.credits) FILTER (WHERE d.kind = 'teaching' AND d.semester IS NULL), 0) AS other_teaching,
       COALESCE(SUM(d.credits) FILTER (WHERE d.kind = 'non_teaching'), 0)                 AS non_teaching,
       COALESCE(SUM(d.credits), 0)                                                        AS total,
       sy.target_credits - COALESCE(SUM(d.credits), 0)                                    AS remaining
  FROM staff_year sy
  JOIN staff s ON s.id = sy.staff_id
  LEFT JOIN v_allocation_detail d ON d.staff_id = sy.staff_id
                                 AND d.academic_year_id = sy.academic_year_id
 GROUP BY sy.academic_year_id, sy.staff_id, s.staff_code, s.forename, s.surname, sy.staff_group_id,
          sy.contract_type, sy.fte, sy.target_credits;

-- Budget vs allocated for every occurrence / category (Module Allocation).
CREATE VIEW v_teaching_role_status AS
SELECT tr.academic_year_id,
       tr.activity_id,
       m.id   AS module_id,
       m.code AS module_code,
       m.owning_staff_group_id,
       o.id   AS occurrence_id,
       o.occ_code,
       c.code AS category_code,
       c.name AS category_name,
       tr.budget_credits,
       COALESCE(SUM(aa.credits), 0)                     AS allocated_credits,
       tr.budget_credits - COALESCE(SUM(aa.credits), 0) AS unallocated_credits
  FROM teaching_role tr
  JOIN occurrence o      ON o.id = tr.occurrence_id
  JOIN module m          ON m.id = o.module_id
  JOIN credit_category c ON c.id = tr.credit_category_id
  LEFT JOIN activity_allocation aa ON aa.activity_id = tr.activity_id
 GROUP BY tr.academic_year_id, tr.activity_id, m.id, m.code, m.owning_staff_group_id,
          o.id, o.occ_code, c.code, c.name, tr.budget_credits;

-- Module Leaders / Moderators tab.
CREATE VIEW v_module_leaders AS
SELECT d.academic_year_id,
       d.module_code,
       d.occ_code,
       d.category_code,
       d.staff_id,
       s.forename || ' ' || s.surname AS staff_name
  FROM v_allocation_detail d
  JOIN staff s ON s.id = d.staff_id
 WHERE d.category_code IN ('ML', 'MOD');


-- =============================================================================
-- 12. SEED DATA
-- =============================================================================

-- updated_at triggers for every table that has the column.
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        SELECT table_name
          FROM information_schema.columns
         WHERE table_schema = current_schema()
           AND column_name = 'updated_at'
           AND table_name IN (SELECT table_name FROM information_schema.tables
                               WHERE table_schema = current_schema()
                                 AND table_type = 'BASE TABLE')
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
                       t || '_set_updated_at', t);
    END LOOP;
END $$;

-- Contract statuses. The migration replaces these with the old staff_status rows.
INSERT INTO contract_status (code, description, is_sessional, display_order) VALUES
    ('FT',  'Full time',                    false, 10),
    ('PT',  'Part time',                    false, 20),
    ('HPL', 'Hourly paid / sessional',      true,  30),
    ('NEW', 'New starter',                  false, 40),
    ('TBA', 'To be appointed',              false, 50);

INSERT INTO academic_year (code, start_date, end_date, status)
VALUES ('2026-27', DATE '2026-09-01', DATE '2027-08-31', 'current');

-- Non-department groups. Add the real departments through the app.
INSERT INTO staff_group (code, name, is_subject_group) VALUES
    ('HPL',   'Sessional Staff / HPL',   false),
    ('SMT',   'Senior Management Team',  false),
    ('OTHER', 'Other',                   false);

-- Teaching credit categories (taught_in).
INSERT INTO credit_category (code, name, applies_to, is_timetabled, semester, sort_order) VALUES
    ('S1',  'Semester 1',    'teaching', true,  1,    10),
    ('S2',  'Semester 2',    'teaching', true,  2,    20),
    ('SUP', 'Supervision',   'teaching', false, NULL, 30),
    ('ML',  'Module Leader', 'teaching', false, NULL, 40),
    ('MOD', 'Moderation',    'teaching', false, NULL, 50),
    ('MC',  'Major Changes', 'teaching', false, NULL, 60);

-- Non-teaching role types, in the order of the old role_type table. The Owner
-- can add, rename and reorder these in the app (rows with applies_to =
-- 'non_teaching'); the migration replaces them with the real role_type rows.
INSERT INTO credit_category (code, name, applies_to, is_management, sort_order) VALUES
    ('MG', 'Management - General',                    'non_teaching', true,  110),
    ('MP', 'Management - Programmes',                 'non_teaching', true,  120),
    ('MR', 'Management - Recruitment & International','non_teaching', true,  130),
    ('ML-M','Management - Learning & Teaching',        'non_teaching', true,  140),
    ('MS', 'Management - Research',                   'non_teaching', true,  150),
    ('ME', 'Management - External Engagement',        'non_teaching', true,  160),
    ('PR', 'Programmes',                              'non_teaching', false, 170),
    ('LT', 'Learning & Teaching',                     'non_teaching', false, 180),
    ('RS', 'Research',                                'non_teaching', false, 190),
    ('EE', 'External Engagement',                     'non_teaching', false, 200);


-- =============================================================================
-- 13. FIRST-OWNER BOOTSTRAP
-- =============================================================================
-- The app can't grant the first Owner because no Owner exists yet. Run this
-- once after deployment, naming the Resourcing Lead:
--
--   SELECT bootstrap_first_owner('smij1', 'first.last@worc.ac.uk', 'Forename', 'Surname');
--
-- It refuses to run if any Owner already exists, so it is safe to leave in
-- place. It queues an invite; the person sets their own password from the email.

CREATE FUNCTION bootstrap_first_owner(p_staff_code text,
                                      p_email    text,
                                      p_forename text,
                                      p_surname  text)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_staff   integer;
    v_account integer;
BEGIN
    IF EXISTS (SELECT 1 FROM user_account WHERE system_role = 'owner') THEN
        RAISE EXCEPTION 'An Owner already exists - use the application to grant roles';
    END IF;

    SELECT id INTO v_staff FROM staff WHERE lower(email) = lower(p_email);
    IF v_staff IS NULL THEN
        INSERT INTO staff (staff_code, forename, surname, email)
        VALUES (p_staff_code, p_forename, p_surname, p_email)
        RETURNING id INTO v_staff;              -- trigger creates the account
    END IF;

    UPDATE user_account
       SET system_role = 'owner', is_active = true
     WHERE staff_id = v_staff
    RETURNING id INTO v_account;

    INSERT INTO auth_token (user_account_id, purpose) VALUES (v_account, 'invite');

    INSERT INTO audit_log (action, entity_type, entity_id, after_data)
    VALUES ('role_change', 'user_account', v_account::text,
            jsonb_build_object('system_role', 'owner', 'via', 'bootstrap_first_owner'));

    RETURN v_account;
END $$;

COMMIT;

-- =============================================================================
-- PERMISSIONS (run separately, as a database superuser)
-- =============================================================================
-- The web app should connect as a limited login role, never as the database
-- owner. That role can read and write data but cannot change the schema, and
-- cannot rewrite or delete the audit trail.
--
--   CREATE ROLE rm_app LOGIN PASSWORD '<generate a strong one; keep it out of documents>';
--   GRANT USAGE ON SCHEMA public TO rm_app;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO rm_app;
--   GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO rm_app;
--   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO rm_app;
--   REVOKE UPDATE, DELETE ON audit_log FROM rm_app;
--   REVOKE EXECUTE ON FUNCTION bootstrap_first_owner(text, text, text, text) FROM rm_app, PUBLIC;
-- =============================================================================

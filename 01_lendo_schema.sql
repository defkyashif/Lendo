-- ============================================================================
-- LENDO — PostgreSQL 18 database schema
-- Scope: peer-to-peer rental marketplace (Borrower + Lender)
-- Run this file while connected to database: lendo
-- ============================================================================

BEGIN;
SET search_path = public;

-- ---------------------------------------------------------------------------
-- 1. USERS, ROLES AND IDENTITY VERIFICATION
-- ---------------------------------------------------------------------------
CREATE TABLE app_users (
    user_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email               VARCHAR(320) NOT NULL,
    password_hash       TEXT NOT NULL,
    first_name          VARCHAR(80) NOT NULL,
    last_name           VARCHAR(80) NOT NULL,
    phone_e164          VARCHAR(20),
    avatar_url          TEXT,
    bio                 TEXT,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    email_verified_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_app_users_email_lower ON app_users (LOWER(email));

CREATE TABLE user_roles (
    user_id     BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE CASCADE,
    role_name   VARCHAR(20) NOT NULL CHECK (role_name IN ('borrower', 'lender', 'admin')),
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, role_name)
);

CREATE TABLE identity_verifications (
    verification_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id              BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE CASCADE,
    document_type        VARCHAR(30) NOT NULL CHECK (document_type IN ('national_id', 'passport', 'driving_license')),
    document_storage_key TEXT NOT NULL,
    status               VARCHAR(20) NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'approved', 'rejected')),
    submitted_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_by_user_id  BIGINT REFERENCES app_users(user_id) ON DELETE SET NULL,
    reviewed_at          TIMESTAMPTZ,
    reviewer_notes       TEXT,
    CHECK ((status = 'pending' AND reviewed_at IS NULL)
        OR (status IN ('approved', 'rejected') AND reviewed_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_identity_verification_pending
    ON identity_verifications(user_id) WHERE status = 'pending';
CREATE INDEX ix_identity_verifications_status ON identity_verifications(status, submitted_at);

-- ---------------------------------------------------------------------------
-- 2. CATALOGUE, LISTINGS, PHOTOS AND LOCATIONS
-- ---------------------------------------------------------------------------
CREATE TABLE categories (
    category_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id   BIGINT REFERENCES categories(category_id) ON DELETE SET NULL,
    name        VARCHAR(100) NOT NULL,
    slug        VARCHAR(120) NOT NULL UNIQUE,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (parent_id, name)
);

CREATE TABLE listings (
    listing_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id         BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    category_id      BIGINT NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    title            VARCHAR(160) NOT NULL,
    description      TEXT NOT NULL,
    item_condition   VARCHAR(20) NOT NULL
                     CHECK (item_condition IN ('new', 'like_new', 'good', 'fair', 'poor')),
    status           VARCHAR(20) NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft', 'published', 'paused', 'archived')),
    rate_amount      NUMERIC(12,2) NOT NULL CHECK (rate_amount > 0),
    rate_unit        VARCHAR(10) NOT NULL CHECK (rate_unit IN ('hour', 'day')),
    currency         CHAR(3) NOT NULL DEFAULT 'BGN' CHECK (currency ~ '^[A-Z]{3}$'),
    deposit_percent  NUMERIC(5,2) NOT NULL DEFAULT 20.00
                     CHECK (deposit_percent >= 0 AND deposit_percent <= 100),
    search_vector    TSVECTOR GENERATED ALWAYS AS (
                         TO_TSVECTOR('simple', COALESCE(title, '') || ' ' || COALESCE(description, ''))
                     ) STORED,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_listings_owner_status ON listings(owner_id, status);
CREATE INDEX ix_listings_category_status ON listings(category_id, status);
CREATE INDEX ix_listings_rate ON listings(rate_amount, currency) WHERE status = 'published';
CREATE INDEX ix_listings_search_vector ON listings USING GIN(search_vector);

CREATE TABLE listing_photos (
    photo_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id   BIGINT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    photo_url    TEXT NOT NULL,
    sort_order   SMALLINT NOT NULL DEFAULT 1 CHECK (sort_order > 0),
    is_primary   BOOLEAN NOT NULL DEFAULT FALSE,
    uploaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (listing_id, sort_order)
);
CREATE UNIQUE INDEX uq_listing_primary_photo ON listing_photos(listing_id) WHERE is_primary;

CREATE TABLE listing_locations (
    listing_id      BIGINT PRIMARY KEY REFERENCES listings(listing_id) ON DELETE CASCADE,
    address_line1   VARCHAR(180) NOT NULL,
    address_line2   VARCHAR(180),
    city            VARCHAR(100) NOT NULL,
    region          VARCHAR(100),
    postal_code     VARCHAR(20),
    country_code    CHAR(2) NOT NULL DEFAULT 'BG' CHECK (country_code ~ '^[A-Z]{2}$'),
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6),
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
    CHECK ((latitude IS NULL AND longitude IS NULL)
        OR (latitude IS NOT NULL AND longitude IS NOT NULL))
);
CREATE INDEX ix_listing_locations_city ON listing_locations(country_code, city, postal_code);

CREATE TABLE listing_unavailability (
    unavailability_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id        BIGINT NOT NULL REFERENCES listings(listing_id) ON DELETE CASCADE,
    created_by_user_id BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    starts_at         TIMESTAMPTZ NOT NULL,
    ends_at           TIMESTAMPTZ NOT NULL,
    reason            VARCHAR(160),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (ends_at > starts_at)
);
CREATE INDEX ix_listing_unavailability_period ON listing_unavailability(listing_id, starts_at, ends_at);

-- ---------------------------------------------------------------------------
-- 3. BOOKINGS, AVAILABILITY AND EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE TABLE bookings (
    booking_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id          BIGINT NOT NULL REFERENCES listings(listing_id) ON DELETE RESTRICT,
    borrower_id         BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    starts_at           TIMESTAMPTZ NOT NULL,
    ends_at             TIMESTAMPTZ NOT NULL,
    status              VARCHAR(24) NOT NULL DEFAULT 'requested'
                        CHECK (status IN (
                            'requested', 'accepted', 'awaiting_deposit', 'confirmed',
                            'active', 'return_pending', 'completed', 'rejected',
                            'cancelled', 'expired', 'disputed'
                        )),
    rental_amount       NUMERIC(12,2) NOT NULL CHECK (rental_amount >= 0),
    deposit_amount      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deposit_amount >= 0),
    service_fee_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (service_fee_amount >= 0),
    currency            CHAR(3) NOT NULL DEFAULT 'BGN' CHECK (currency ~ '^[A-Z]{3}$'),
    special_requests    TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (ends_at > starts_at)
);
CREATE INDEX ix_bookings_listing_period ON bookings(listing_id, starts_at, ends_at);
CREATE INDEX ix_bookings_borrower_status ON bookings(borrower_id, status, created_at DESC);
CREATE INDEX ix_bookings_status_created ON bookings(status, created_at DESC);

-- Deposit amount is calculated from the listing's deposit percentage (20% by default).
CREATE OR REPLACE FUNCTION lendo_calculate_booking_deposit()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_deposit_percent NUMERIC(5,2);
BEGIN
    SELECT deposit_percent INTO v_deposit_percent
    FROM listings WHERE listing_id = NEW.listing_id;
    IF FOUND THEN
        NEW.deposit_amount := ROUND(NEW.rental_amount * v_deposit_percent / 100.0, 2);
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_bookings_calculate_deposit
BEFORE INSERT OR UPDATE OF listing_id, rental_amount ON bookings
FOR EACH ROW EXECUTE FUNCTION lendo_calculate_booking_deposit();

CREATE TABLE booking_status_history (
    history_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id          BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    previous_status     VARCHAR(24),
    new_status          VARCHAR(24) NOT NULL,
    changed_by_user_id  BIGINT REFERENCES app_users(user_id) ON DELETE SET NULL,
    change_note         TEXT,
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_booking_status_history_booking ON booking_status_history(booking_id, changed_at);

CREATE TABLE booking_extensions (
    extension_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id            BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    requested_by_user_id  BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    reviewed_by_user_id   BIGINT REFERENCES app_users(user_id) ON DELETE SET NULL,
    previous_ends_at      TIMESTAMPTZ NOT NULL,
    requested_ends_at     TIMESTAMPTZ NOT NULL,
    additional_amount     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (additional_amount >= 0),
    status                VARCHAR(20) NOT NULL DEFAULT 'requested'
                          CHECK (status IN ('requested', 'approved', 'rejected', 'cancelled')),
    request_note          TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at           TIMESTAMPTZ,
    CHECK (requested_ends_at > previous_ends_at)
);
CREATE INDEX ix_booking_extensions_booking ON booking_extensions(booking_id, status);

-- An extension may be requested by either participant while the rental is active.
-- Approval must come from the other participant; on approval the booking end date is updated.
CREATE OR REPLACE FUNCTION lendo_validate_booking_extension()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_ends_at TIMESTAMPTZ;
    v_booking_status VARCHAR(24);
BEGIN
    SELECT b.borrower_id, l.owner_id, b.ends_at, b.status
      INTO v_borrower_id, v_owner_id, v_ends_at, v_booking_status
    FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
    WHERE b.booking_id = NEW.booking_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking for extension does not exist.';
    END IF;
    IF NEW.requested_by_user_id NOT IN (v_borrower_id, v_owner_id) THEN
        RAISE EXCEPTION 'Only the borrower or lender may request an extension.';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF v_booking_status <> 'active' THEN
            RAISE EXCEPTION 'A rental extension can be requested only while the rental is active.';
        END IF;
        IF NEW.previous_ends_at IS DISTINCT FROM v_ends_at OR NEW.requested_ends_at <= v_ends_at THEN
            RAISE EXCEPTION 'The requested extension must start from the current end date and extend it.';
        END IF;
    ELSE
        IF NEW.status IN ('approved', 'rejected') THEN
            IF NEW.reviewed_by_user_id IS NULL OR NEW.reviewed_by_user_id = NEW.requested_by_user_id THEN
                RAISE EXCEPTION 'The other booking participant must review the extension.';
            END IF;
            IF NEW.reviewed_by_user_id NOT IN (v_borrower_id, v_owner_id) THEN
                RAISE EXCEPTION 'Only the other booking participant may review the extension.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_booking_extensions_validate
BEFORE INSERT OR UPDATE ON booking_extensions
FOR EACH ROW EXECUTE FUNCTION lendo_validate_booking_extension();

CREATE OR REPLACE FUNCTION lendo_apply_approved_extension()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
        UPDATE bookings
        SET ends_at = NEW.requested_ends_at,
            rental_amount = rental_amount + NEW.additional_amount
        WHERE booking_id = NEW.booking_id;
        -- The bookings availability trigger checks the extended period for conflicts.
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_booking_extensions_apply
AFTER UPDATE OF status ON booking_extensions
FOR EACH ROW EXECUTE FUNCTION lendo_apply_approved_extension();

-- ---------------------------------------------------------------------------
-- 4. PAYMENTS AND LENDER PAYOUTS
-- ---------------------------------------------------------------------------
CREATE TABLE payments (
    payment_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id          BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE RESTRICT,
    payer_user_id       BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    payee_user_id       BIGINT REFERENCES app_users(user_id) ON DELETE RESTRICT,
    payment_type        VARCHAR(20) NOT NULL
                        CHECK (payment_type IN ('security_deposit', 'rental_fee', 'service_fee', 'refund')),
    amount              NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    currency            CHAR(3) NOT NULL DEFAULT 'BGN' CHECK (currency ~ '^[A-Z]{3}$'),
    status              VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'processing', 'succeeded', 'failed', 'refunded', 'partially_refunded')),
    provider            VARCHAR(60),
    provider_reference  VARCHAR(180),
    receipt_url         TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    paid_at             TIMESTAMPTZ,
    UNIQUE (provider, provider_reference)
);
CREATE INDEX ix_payments_booking_status ON payments(booking_id, status);
CREATE INDEX ix_payments_payer_created ON payments(payer_user_id, created_at DESC);

CREATE TABLE payout_accounts (
    payout_account_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id               BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE CASCADE,
    provider              VARCHAR(60) NOT NULL,
    provider_account_token TEXT NOT NULL UNIQUE,
    bank_name             VARCHAR(120),
    account_holder_name   VARCHAR(160),
    account_last4         CHAR(4),
    currency              CHAR(3) NOT NULL DEFAULT 'BGN' CHECK (currency ~ '^[A-Z]{3}$'),
    is_verified           BOOLEAN NOT NULL DEFAULT FALSE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_payout_accounts_user ON payout_accounts(user_id);

CREATE TABLE payouts (
    payout_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id         BIGINT REFERENCES bookings(booking_id) ON DELETE SET NULL,
    user_id            BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    payout_account_id  BIGINT NOT NULL REFERENCES payout_accounts(payout_account_id) ON DELETE RESTRICT,
    amount             NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    currency           CHAR(3) NOT NULL DEFAULT 'BGN' CHECK (currency ~ '^[A-Z]{3}$'),
    status             VARCHAR(20) NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'processing', 'paid', 'failed', 'cancelled')),
    provider_reference VARCHAR(180) UNIQUE,
    initiated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    paid_at            TIMESTAMPTZ
);
CREATE INDEX ix_payouts_user_status ON payouts(user_id, status, initiated_at DESC);

-- ---------------------------------------------------------------------------
-- 5. HANDOVER, RETURN AND ITEM-CONDITION REPORTS
-- ---------------------------------------------------------------------------
CREATE TABLE handover_confirmations (
    confirmation_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id         BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    stage              VARCHAR(10) NOT NULL CHECK (stage IN ('pickup', 'return')),
    confirmed_by_user_id BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    confirmed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes              TEXT,
    UNIQUE (booking_id, stage, confirmed_by_user_id)
);
CREATE INDEX ix_handover_confirmations_booking ON handover_confirmations(booking_id, stage);

CREATE TABLE condition_reports (
    condition_report_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id          BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    stage               VARCHAR(10) NOT NULL CHECK (stage IN ('pickup', 'return')),
    submitted_by_user_id BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    item_condition      VARCHAR(20) NOT NULL
                        CHECK (item_condition IN ('new', 'like_new', 'good', 'fair', 'poor', 'damaged')),
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (booking_id, stage, submitted_by_user_id)
);

CREATE OR REPLACE FUNCTION lendo_guard_condition_report()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_status VARCHAR(24);
BEGIN
    SELECT b.borrower_id, l.owner_id, b.status
      INTO v_borrower_id, v_owner_id, v_status
    FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
    WHERE b.booking_id = NEW.booking_id;

    IF NOT FOUND OR NEW.submitted_by_user_id NOT IN (v_borrower_id, v_owner_id) THEN
        RAISE EXCEPTION 'Only the borrower and lender may submit item-condition reports.';
    END IF;
    IF NEW.stage = 'pickup' AND v_status NOT IN ('confirmed', 'active') THEN
        RAISE EXCEPTION 'Pickup condition reports require a confirmed or active booking.';
    END IF;
    IF NEW.stage = 'return' AND v_status NOT IN ('active', 'return_pending', 'completed') THEN
        RAISE EXCEPTION 'Return condition reports require an active, return-pending or completed booking.';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_condition_reports_guard
BEFORE INSERT ON condition_reports
FOR EACH ROW EXECUTE FUNCTION lendo_guard_condition_report();

CREATE TABLE condition_report_photos (
    condition_photo_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    condition_report_id BIGINT NOT NULL REFERENCES condition_reports(condition_report_id) ON DELETE CASCADE,
    photo_url           TEXT NOT NULL,
    uploaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- 6. IN-APP CHAT AND NOTIFICATIONS
-- ---------------------------------------------------------------------------
CREATE TABLE conversations (
    conversation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id      BIGINT NOT NULL UNIQUE REFERENCES bookings(booking_id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE messages (
    message_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id  BIGINT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
    sender_user_id   BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    message_body     TEXT,
    attachment_url   TEXT,
    sent_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at          TIMESTAMPTZ,
    CHECK (NULLIF(BTRIM(message_body), '') IS NOT NULL OR attachment_url IS NOT NULL)
);
CREATE INDEX ix_messages_conversation_sent ON messages(conversation_id, sent_at);

CREATE TABLE notifications (
    notification_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recipient_user_id BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE CASCADE,
    actor_user_id     BIGINT REFERENCES app_users(user_id) ON DELETE SET NULL,
    booking_id        BIGINT REFERENCES bookings(booking_id) ON DELETE CASCADE,
    notification_type VARCHAR(60) NOT NULL,
    title             VARCHAR(160) NOT NULL,
    body              TEXT NOT NULL,
    payload           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at           TIMESTAMPTZ
);
CREATE INDEX ix_notifications_unread ON notifications(recipient_user_id, created_at DESC)
    WHERE read_at IS NULL;

-- ---------------------------------------------------------------------------
-- 7. REVIEWS, REPORTS AND SUPPORT
-- ---------------------------------------------------------------------------
CREATE TABLE reviews (
    review_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id         BIGINT NOT NULL REFERENCES bookings(booking_id) ON DELETE RESTRICT,
    listing_id         BIGINT NOT NULL REFERENCES listings(listing_id) ON DELETE RESTRICT,
    reviewer_user_id   BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    reviewee_user_id   BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    overall_rating     SMALLINT NOT NULL CHECK (overall_rating BETWEEN 1 AND 5),
    communication_rating SMALLINT CHECK (communication_rating BETWEEN 1 AND 5),
    item_care_rating   SMALLINT CHECK (item_care_rating BETWEEN 1 AND 5),
    comment            TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (booking_id, reviewer_user_id),
    CHECK (reviewer_user_id <> reviewee_user_id)
);
CREATE INDEX ix_reviews_reviewee ON reviews(reviewee_user_id, created_at DESC);
CREATE INDEX ix_reviews_listing ON reviews(listing_id, created_at DESC);

CREATE TABLE review_reports (
    review_report_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    review_id         BIGINT NOT NULL REFERENCES reviews(review_id) ON DELETE CASCADE,
    reported_by_user_id BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    reason            TEXT NOT NULL,
    status            VARCHAR(20) NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open', 'under_review', 'resolved', 'dismissed')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at       TIMESTAMPTZ
);

CREATE TABLE support_tickets (
    ticket_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id           BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    booking_id        BIGINT REFERENCES bookings(booking_id) ON DELETE SET NULL,
    category          VARCHAR(40) NOT NULL
                      CHECK (category IN ('booking', 'payment', 'verification', 'item_condition', 'account', 'other')),
    subject           VARCHAR(180) NOT NULL,
    description       TEXT NOT NULL,
    priority          VARCHAR(10) NOT NULL DEFAULT 'normal'
                      CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    status            VARCHAR(20) NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_support_tickets_user_status ON support_tickets(user_id, status, created_at DESC);

CREATE TABLE support_ticket_messages (
    ticket_message_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id         BIGINT NOT NULL REFERENCES support_tickets(ticket_id) ON DELETE CASCADE,
    sender_user_id    BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE RESTRICT,
    message_body      TEXT NOT NULL,
    attachment_url    TEXT,
    sent_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_support_ticket_messages_ticket ON support_ticket_messages(ticket_id, sent_at);

CREATE TABLE guideline_acceptances (
    acceptance_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        BIGINT NOT NULL REFERENCES app_users(user_id) ON DELETE CASCADE,
    guideline_version VARCHAR(30) NOT NULL,
    accepted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, guideline_version)
);

-- ---------------------------------------------------------------------------
-- 8. SHARED TRIGGER FUNCTIONS AND BUSINESS RULES
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lendo_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_app_users_updated_at
BEFORE UPDATE ON app_users FOR EACH ROW EXECUTE FUNCTION lendo_set_updated_at();
CREATE TRIGGER trg_listings_updated_at
BEFORE UPDATE ON listings FOR EACH ROW EXECUTE FUNCTION lendo_set_updated_at();
CREATE TRIGGER trg_bookings_updated_at
BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION lendo_set_updated_at();
CREATE TRIGGER trg_support_tickets_updated_at
BEFORE UPDATE ON support_tickets FOR EACH ROW EXECUTE FUNCTION lendo_set_updated_at();

-- A listing cannot be published until it has a location and at least 3 photos.
CREATE OR REPLACE FUNCTION lendo_validate_listing_publication()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_photo_count INTEGER;
BEGIN
    IF NEW.status = 'published' THEN
        SELECT COUNT(*) INTO v_photo_count
        FROM listing_photos WHERE listing_id = NEW.listing_id;

        IF v_photo_count < 3 THEN
            RAISE EXCEPTION 'A listing needs at least 3 photos before publication.';
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM user_roles
            WHERE user_id = NEW.owner_id AND role_name = 'lender'
        ) THEN
            RAISE EXCEPTION 'The listing owner must have the lender role.';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM listing_locations WHERE listing_id = NEW.listing_id) THEN
            RAISE EXCEPTION 'A listing needs a location before publication.';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_listings_validate_publication
BEFORE INSERT OR UPDATE OF status ON listings
FOR EACH ROW EXECUTE FUNCTION lendo_validate_listing_publication();

-- A published listing must retain at least 3 photos (not only at publish time).
CREATE OR REPLACE FUNCTION lendo_keep_minimum_listing_photos()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_listing_status VARCHAR(20);
    v_photo_count INTEGER;
BEGIN
    IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.listing_id IS DISTINCT FROM NEW.listing_id) THEN
        SELECT status INTO v_listing_status FROM listings WHERE listing_id = OLD.listing_id;
        IF v_listing_status = 'published' THEN
            SELECT COUNT(*) INTO v_photo_count
            FROM listing_photos WHERE listing_id = OLD.listing_id;
            IF v_photo_count <= 3 THEN
                RAISE EXCEPTION 'A published listing must keep at least 3 photos.';
            END IF;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_listing_photos_keep_minimum
BEFORE DELETE OR UPDATE OF listing_id ON listing_photos
FOR EACH ROW EXECUTE FUNCTION lendo_keep_minimum_listing_photos();

-- Prevent a user from booking their own listing and prevent overlapping active requests.
-- An advisory transaction lock serializes concurrent booking attempts for the same listing.
CREATE OR REPLACE FUNCTION lendo_check_booking_availability()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_owner_id BIGINT;
    v_listing_status VARCHAR(20);
BEGIN
    SELECT owner_id, status INTO v_owner_id, v_listing_status
    FROM listings WHERE listing_id = NEW.listing_id;

    IF NOT FOUND THEN
        RETURN NEW; -- The FK will report a missing listing.
    END IF;

    IF NEW.borrower_id = v_owner_id THEN
        RAISE EXCEPTION 'A lender cannot book their own listing.';
    END IF;

    IF TG_OP = 'INSERT' AND v_listing_status <> 'published' THEN
        RAISE EXCEPTION 'Only published listings can be booked.';
    END IF;

    IF TG_OP = 'INSERT' AND NOT EXISTS (
        SELECT 1 FROM user_roles WHERE user_id = NEW.borrower_id AND role_name = 'borrower'
    ) THEN
        RAISE EXCEPTION 'The booking user must have the borrower role.';
    END IF;

    IF NEW.status IN ('requested', 'accepted', 'awaiting_deposit', 'confirmed', 'active', 'return_pending', 'disputed') THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('lendo:listing:' || NEW.listing_id::TEXT, 0));

        IF EXISTS (
            SELECT 1 FROM bookings b
            WHERE b.listing_id = NEW.listing_id
              AND b.booking_id <> COALESCE(NEW.booking_id, -1)
              AND b.status IN ('requested', 'accepted', 'awaiting_deposit', 'confirmed', 'active', 'return_pending', 'disputed')
              AND b.starts_at < NEW.ends_at
              AND b.ends_at > NEW.starts_at
        ) THEN
            RAISE EXCEPTION 'The selected rental period overlaps another booking.';
        END IF;

        IF EXISTS (
            SELECT 1 FROM listing_unavailability u
            WHERE u.listing_id = NEW.listing_id
              AND u.starts_at < NEW.ends_at
              AND u.ends_at > NEW.starts_at
        ) THEN
            RAISE EXCEPTION 'The listing is blocked for part of the selected rental period.';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_bookings_check_availability
BEFORE INSERT OR UPDATE OF listing_id, borrower_id, starts_at, ends_at, status ON bookings
FOR EACH ROW EXECUTE FUNCTION lendo_check_booking_availability();

-- Only the listing owner may create blocked calendar dates; existing bookings cannot be blocked.
CREATE OR REPLACE FUNCTION lendo_check_unavailability_owner()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_owner_id BIGINT;
BEGIN
    SELECT owner_id INTO v_owner_id FROM listings WHERE listing_id = NEW.listing_id;
    IF NEW.created_by_user_id <> v_owner_id THEN
        RAISE EXCEPTION 'Only the listing owner may block listing availability.';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('lendo:listing:' || NEW.listing_id::TEXT, 0));
    IF EXISTS (
        SELECT 1 FROM bookings b
        WHERE b.listing_id = NEW.listing_id
          AND b.status IN ('requested', 'accepted', 'awaiting_deposit', 'confirmed', 'active', 'return_pending', 'disputed')
          AND b.starts_at < NEW.ends_at AND b.ends_at > NEW.starts_at
    ) THEN
        RAISE EXCEPTION 'Unavailable dates overlap an existing booking.';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_listing_unavailability_owner
BEFORE INSERT OR UPDATE ON listing_unavailability
FOR EACH ROW EXECUTE FUNCTION lendo_check_unavailability_owner();

-- Record every booking status transition for traceability.
CREATE OR REPLACE FUNCTION lendo_record_booking_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_actor_id BIGINT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO booking_status_history(booking_id, previous_status, new_status, changed_by_user_id)
        VALUES (NEW.booking_id, NULL, NEW.status, NEW.borrower_id);
    ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
        v_actor_id := COALESCE(NULLIF(current_setting('app.user_id', TRUE), '')::BIGINT, NEW.borrower_id);
        INSERT INTO booking_status_history(booking_id, previous_status, new_status, changed_by_user_id)
        VALUES (NEW.booking_id, OLD.status, NEW.status, v_actor_id);
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_bookings_record_status
AFTER INSERT OR UPDATE OF status ON bookings
FOR EACH ROW EXECUTE FUNCTION lendo_record_booking_status();

-- Enforce a valid booking lifecycle (including the automatic handover transitions).
CREATE OR REPLACE FUNCTION lendo_validate_booking_status_transition()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (OLD.status = 'requested' AND NEW.status IN ('accepted', 'rejected', 'cancelled', 'expired')) OR
        (OLD.status = 'accepted' AND NEW.status IN ('awaiting_deposit', 'cancelled')) OR
        (OLD.status = 'awaiting_deposit' AND NEW.status IN ('confirmed', 'cancelled', 'expired')) OR
        (OLD.status = 'confirmed' AND NEW.status IN ('active', 'cancelled')) OR
        (OLD.status = 'active' AND NEW.status IN ('return_pending', 'completed', 'disputed')) OR
        (OLD.status = 'return_pending' AND NEW.status IN ('completed', 'disputed')) OR
        (OLD.status = 'disputed' AND NEW.status IN ('completed', 'cancelled'))
    ) THEN
        RAISE EXCEPTION 'Invalid booking status transition: % -> %.', OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_bookings_validate_status_transition
BEFORE UPDATE OF status ON bookings
FOR EACH ROW EXECUTE FUNCTION lendo_validate_booking_status_transition();

-- A security-deposit payment must match the borrower, listing owner, quoted amount and currency.
CREATE OR REPLACE FUNCTION lendo_validate_security_deposit()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_deposit_amount NUMERIC(12,2);
    v_booking_currency CHAR(3);
BEGIN
    IF NEW.payment_type = 'security_deposit' THEN
        SELECT b.borrower_id, l.owner_id, b.deposit_amount, b.currency
          INTO v_borrower_id, v_owner_id, v_deposit_amount, v_booking_currency
        FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
        WHERE b.booking_id = NEW.booking_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'A security deposit must reference an existing booking.';
        END IF;
        IF NEW.payer_user_id <> v_borrower_id THEN
            RAISE EXCEPTION 'The borrower must pay the security deposit.';
        END IF;
        IF NEW.payee_user_id IS NOT NULL AND NEW.payee_user_id <> v_owner_id THEN
            RAISE EXCEPTION 'The security deposit payee must be the listing owner.';
        END IF;
        IF NEW.amount <> v_deposit_amount OR NEW.currency <> v_booking_currency THEN
            RAISE EXCEPTION 'Security-deposit amount and currency must match the booking quote.';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_payments_validate_security_deposit
BEFORE INSERT OR UPDATE OF booking_id, payer_user_id, payee_user_id, payment_type, amount, currency ON payments
FOR EACH ROW EXECUTE FUNCTION lendo_validate_security_deposit();

-- Successful deposit payment confirms the booking, creates the chat and stores notifications.
CREATE OR REPLACE FUNCTION lendo_on_security_deposit_paid()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
BEGIN
    IF NEW.payment_type = 'security_deposit' AND NEW.status = 'succeeded'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'succeeded') THEN
        SELECT b.borrower_id, l.owner_id INTO v_borrower_id, v_owner_id
        FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
        WHERE b.booking_id = NEW.booking_id;

        UPDATE bookings SET status = 'confirmed'
        WHERE booking_id = NEW.booking_id AND status = 'awaiting_deposit';

        INSERT INTO conversations(booking_id)
        VALUES (NEW.booking_id)
        ON CONFLICT (booking_id) DO NOTHING;

        INSERT INTO notifications(recipient_user_id, actor_user_id, booking_id, notification_type, title, body)
        VALUES
            (v_owner_id, v_borrower_id, NEW.booking_id, 'deposit_paid', 'Deposit received', 'The security deposit has been paid successfully.'),
            (v_borrower_id, v_borrower_id, NEW.booking_id, 'deposit_paid', 'Deposit paid', 'Your security deposit payment was successful. You can now contact the lender.');
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_payments_after_security_deposit
AFTER INSERT OR UPDATE OF status ON payments
FOR EACH ROW EXECUTE FUNCTION lendo_on_security_deposit_paid();

-- Chat is available only after a successful security-deposit payment and only to both parties.
CREATE OR REPLACE FUNCTION lendo_guard_message_access()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_booking_status VARCHAR(24);
BEGIN
    SELECT b.borrower_id, l.owner_id, b.status
      INTO v_borrower_id, v_owner_id, v_booking_status
    FROM conversations c
    JOIN bookings b ON b.booking_id = c.booking_id
    JOIN listings l ON l.listing_id = b.listing_id
    WHERE c.conversation_id = NEW.conversation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation does not have a valid booking.';
    END IF;
    IF NEW.sender_user_id NOT IN (v_borrower_id, v_owner_id) THEN
        RAISE EXCEPTION 'Only the borrower and lender may use this conversation.';
    END IF;
    IF v_booking_status NOT IN ('confirmed', 'active', 'return_pending', 'completed', 'disputed')
       OR NOT EXISTS (
            SELECT 1 FROM conversations c
            JOIN payments p ON p.booking_id = c.booking_id
            WHERE c.conversation_id = NEW.conversation_id
              AND p.payment_type = 'security_deposit'
              AND p.status = 'succeeded'
       ) THEN
        RAISE EXCEPTION 'Chat unlocks after the security deposit has been paid successfully.';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_messages_guard_access
BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION lendo_guard_message_access();

-- Reviews can be added only after completion and only between the booking participants.
CREATE OR REPLACE FUNCTION lendo_guard_review()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_listing_id BIGINT;
    v_booking_status VARCHAR(24);
BEGIN
    SELECT b.borrower_id, l.owner_id, b.listing_id, b.status
      INTO v_borrower_id, v_owner_id, v_listing_id, v_booking_status
    FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
    WHERE b.booking_id = NEW.booking_id;

    IF NOT FOUND OR v_booking_status <> 'completed' THEN
        RAISE EXCEPTION 'A review can be submitted only after the rental is completed.';
    END IF;
    IF NEW.listing_id <> v_listing_id THEN
        RAISE EXCEPTION 'Review listing_id must match the booked listing.';
    END IF;
    IF NEW.reviewer_user_id = v_borrower_id AND NEW.reviewee_user_id = v_owner_id THEN
        RETURN NEW;
    ELSIF NEW.reviewer_user_id = v_owner_id AND NEW.reviewee_user_id = v_borrower_id THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Reviews are allowed only between the borrower and lender in this booking.';
END;
$function$;
CREATE TRIGGER trg_reviews_guard
BEFORE INSERT OR UPDATE ON reviews FOR EACH ROW EXECUTE FUNCTION lendo_guard_review();

-- A lender reviewing a borrower must rate communication and item care.
CREATE OR REPLACE FUNCTION lendo_require_borrower_review_dimensions()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
BEGIN
    SELECT b.borrower_id, l.owner_id INTO v_borrower_id, v_owner_id
    FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
    WHERE b.booking_id = NEW.booking_id;

    IF NEW.reviewer_user_id = v_owner_id AND NEW.reviewee_user_id = v_borrower_id
       AND (NEW.communication_rating IS NULL OR NEW.item_care_rating IS NULL) THEN
        RAISE EXCEPTION 'A lender review of a borrower must include Communication and Item Care ratings.';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_reviews_require_dimensions
BEFORE INSERT OR UPDATE ON reviews
FOR EACH ROW EXECUTE FUNCTION lendo_require_borrower_review_dimensions();

-- Low scores are automatically queued for admin moderation.
CREATE OR REPLACE FUNCTION lendo_flag_negative_review()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.overall_rating <= 2
       OR COALESCE(NEW.communication_rating, 5) <= 2
       OR COALESCE(NEW.item_care_rating, 5) <= 2 THEN
        INSERT INTO review_reports(review_id, reported_by_user_id, reason, status)
        VALUES (
            NEW.review_id,
            NEW.reviewer_user_id,
            'Automatically flagged for admin review due to a low rating.',
            'open'
        );
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_reviews_flag_negative
AFTER INSERT ON reviews
FOR EACH ROW EXECUTE FUNCTION lendo_flag_negative_review();

-- Both participants must confirm handover/return; confirmation is stage- and user-specific.
CREATE OR REPLACE FUNCTION lendo_guard_handover_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_borrower_id BIGINT;
    v_owner_id BIGINT;
    v_booking_status VARCHAR(24);
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('lendo:handover:' || NEW.booking_id::TEXT || ':' || NEW.stage, 0));

    SELECT b.borrower_id, l.owner_id, b.status
      INTO v_borrower_id, v_owner_id, v_booking_status
    FROM bookings b JOIN listings l ON l.listing_id = b.listing_id
    WHERE b.booking_id = NEW.booking_id;

    IF NOT FOUND OR NEW.confirmed_by_user_id NOT IN (v_borrower_id, v_owner_id) THEN
        RAISE EXCEPTION 'Only the borrower and lender may confirm handover or return.';
    END IF;
    IF NEW.stage = 'pickup' AND v_booking_status <> 'confirmed' THEN
        RAISE EXCEPTION 'Pickup confirmation is available only for a confirmed booking.';
    END IF;
    IF NEW.stage = 'return' AND v_booking_status NOT IN ('active', 'return_pending') THEN
        RAISE EXCEPTION 'Return confirmation is available only for an active or return-pending booking.';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_handover_confirmations_guard
BEFORE INSERT ON handover_confirmations
FOR EACH ROW EXECUTE FUNCTION lendo_guard_handover_confirmation();

-- When both parties confirm pickup, the booking becomes active.
-- When both parties confirm return, the booking becomes completed.
CREATE OR REPLACE FUNCTION lendo_advance_booking_after_handover()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    v_confirmed_parties INTEGER;
BEGIN
    SELECT COUNT(DISTINCT confirmed_by_user_id) INTO v_confirmed_parties
    FROM handover_confirmations
    WHERE booking_id = NEW.booking_id AND stage = NEW.stage;

    IF v_confirmed_parties >= 2 AND NEW.stage = 'pickup' THEN
        UPDATE bookings SET status = 'active'
        WHERE booking_id = NEW.booking_id AND status = 'confirmed';
    ELSIF v_confirmed_parties >= 2 AND NEW.stage = 'return' THEN
        UPDATE bookings SET status = 'completed'
        WHERE booking_id = NEW.booking_id AND status IN ('active', 'return_pending');
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_handover_advance_booking
AFTER INSERT ON handover_confirmations
FOR EACH ROW EXECUTE FUNCTION lendo_advance_booking_after_handover();

-- ---------------------------------------------------------------------------
-- 9. READ-ONLY VIEWS FOR SEARCH AND CALENDAR
-- ---------------------------------------------------------------------------
-- Public catalogue deliberately excludes exact street address and exact coordinates.
CREATE OR REPLACE VIEW public_listing_catalog AS
SELECT
    l.listing_id,
    l.owner_id,
    l.category_id,
    c.name AS category_name,
    l.title,
    l.description,
    l.item_condition,
    l.rate_amount,
    l.rate_unit,
    l.currency,
    l.deposit_percent,
    loc.city,
    loc.region,
    loc.postal_code,
    ROUND(loc.latitude, 2) AS approximate_latitude,
    ROUND(loc.longitude, 2) AS approximate_longitude,
    l.created_at
FROM listings l
JOIN categories c ON c.category_id = l.category_id
JOIN listing_locations loc ON loc.listing_id = l.listing_id
WHERE l.status = 'published';

-- Calendar view: statuses that reserve a date range.
CREATE OR REPLACE VIEW booking_calendar AS
SELECT booking_id, listing_id, starts_at, ends_at, status
FROM bookings
WHERE status IN ('requested', 'accepted', 'awaiting_deposit', 'confirmed', 'active', 'return_pending', 'disputed');

-- Pickup/return progress: both parties should confirm each stage.
CREATE OR REPLACE VIEW booking_handover_progress AS
SELECT
    booking_id,
    stage,
    COUNT(DISTINCT confirmed_by_user_id) AS confirmed_parties,
    MAX(confirmed_at) AS last_confirmation_at
FROM handover_confirmations
GROUP BY booking_id, stage;

-- Average user reputation used by public profiles (rating is visible after completed rentals).
CREATE OR REPLACE VIEW public_user_ratings AS
SELECT
    reviewee_user_id AS user_id,
    ROUND(AVG(overall_rating)::NUMERIC, 2) AS average_rating,
    COUNT(*) AS review_count,
    ROUND(AVG(communication_rating)::NUMERIC, 2) AS average_communication_rating,
    ROUND(AVG(item_care_rating)::NUMERIC, 2) AS average_item_care_rating
FROM reviews
GROUP BY reviewee_user_id;

-- Average rating for each item/listing.
CREATE OR REPLACE VIEW public_listing_ratings AS
SELECT
    listing_id,
    ROUND(AVG(overall_rating)::NUMERIC, 2) AS average_rating,
    COUNT(*) AS review_count
FROM reviews
GROUP BY listing_id;

-- ---------------------------------------------------------------------------
-- 10. INITIAL CATEGORIES
-- ---------------------------------------------------------------------------
INSERT INTO categories(name, slug) VALUES
    ('Tools & DIY', 'tools-diy'),
    ('Electronics', 'electronics'),
    ('Sports & Outdoors', 'sports-outdoors'),
    ('Home & Garden', 'home-garden'),
    ('Photography', 'photography'),
    ('Musical Instruments', 'musical-instruments'),
    ('Party & Events', 'party-events'),
    ('Other', 'other')
ON CONFLICT (slug) DO NOTHING;

COMMIT;

-- IMPORTANT IMPLEMENTATION NOTES:
-- 1) Store only password hashes (Argon2id/bcrypt); never plaintext passwords.
-- 2) Store document images and payment receipts in private object storage; save storage keys/URLs here.
-- 3) Do not store card numbers, CVV, full bank credentials or raw identity documents in PostgreSQL.
-- 4) Assign user_roles when registering users: borrower by default; add lender when they create listings.
-- 5) The 20% deposit is the default listing setting. A trigger calculates booking.deposit_amount
--    from rental_amount and the listing's deposit_percent; the application creates the payment row.
--    Payment confirmation is webhook-driven.
-- 6) Set transaction-local app.user_id before changing booking status if accurate audit attribution is needed:
--    SET LOCAL app.user_id = '123';
-- 7) The application must expose exact address fields only to booking participants after confirmation.
--    public_listing_catalog intentionally provides approximate location only.
-- 8) Push delivery within 5 seconds is an application/queue responsibility; notifications stores the event.

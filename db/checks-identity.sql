-- =============================================================================
-- Identity gate (screen_sender): each role is let through with its role only;
-- unknown, retired, not-yet-valid, deactivated, ambiguous and malformed
-- senders are refused with nothing from Meridian's data; refusals are audited
-- at most once per sender per 10 minutes.
--   node --env-file=.env.owner scripts/db.mjs db/checks-identity.sql
-- Owner login, BEGIN ... ROLLBACK. Non-zero exit on failure.
-- =============================================================================
BEGIN;
SET LOCAL search_path = meridian, public;

CREATE TEMP TABLE check_results (name text, ok boolean) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_value(p_name text, p_got text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NOT DISTINCT FROM p_want THEN RAISE NOTICE 'PASS  %  ->  %', p_name, p_got;
  ELSE RAISE NOTICE 'FAIL  %: got %, want %', p_name, p_got, p_want; END IF;
  INSERT INTO check_results VALUES (p_name, p_got IS NOT DISTINCT FROM p_want);
END $$;

CREATE FUNCTION pg_temp.wa(p_code text) RETURNS text LANGUAGE sql AS $$
  SELECT c.value FROM meridian.user_contacts c JOIN meridian.users u ON u.id = c.user_id
   WHERE u.employee_code = p_code AND c.channel = 'whatsapp' AND c.valid_to IS NULL $$;
CREATE FUNCTION pg_temp.audits(p_actor text) RETURNS text LANGUAGE sql AS $$
  SELECT count(*)::text FROM meridian.audit_log WHERE action = 'identity.unknown_sender' AND actor = p_actor $$;

DO $t$
DECLARE
  v_known text := '{"result": "unknown_sender"}';
BEGIN
  RAISE NOTICE '--- registered people get through, with their role and nothing else ---';
  PERFORM pg_temp.expect_value('rep on WhatsApp', screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NDL-01')])::text,
    '{"role": "rep", "result": "ok"}');
  PERFORM pg_temp.expect_value('area manager on email', screen_sender('email', ARRAY['vikram.malhotra@meridian.example'])::text,
    '{"role": "area_manager", "result": "ok"}');
  PERFORM pg_temp.expect_value('regional head on WhatsApp', screen_sender('whatsapp', ARRAY[pg_temp.wa('RH-NORTH')])::text,
    '{"role": "regional_head", "result": "ok"}');
  PERFORM pg_temp.expect_value('number written with spaces and dashes', screen_sender('whatsapp',
    ARRAY[regexp_replace(pg_temp.wa('REP-NDL-01'), '^\+91(\d{5})(\d{5})$', '+91 \1-\2')])->>'result', 'ok');
  PERFORM pg_temp.expect_value('email in mixed case with spaces', screen_sender('email', ARRAY['  Vikram.Malhotra@Meridian.EXAMPLE '])->>'result', 'ok');
  PERFORM pg_temp.expect_value('Imran''s replacement number', screen_sender('whatsapp', ARRAY['+919811042017'])->>'result', 'ok');
  PERFORM pg_temp.expect_value('a known person gets no name or id back',
    (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(screen_sender('email', ARRAY['vikram.malhotra@meridian.example'])) k), 'result,role');
  PERFORM pg_temp.expect_value('letting someone through writes no audit row',
    (SELECT count(*)::text FROM meridian.audit_log WHERE action = 'identity.unknown_sender' AND actor LIKE 'unknown:%meridian.example'), '0');

  RAISE NOTICE '--- everyone else gets the same bare refusal ---';
  PERFORM pg_temp.expect_value('unknown WhatsApp number', screen_sender('whatsapp', ARRAY['+91 77777 12345'])::text, v_known);
  PERFORM pg_temp.expect_value('unknown email', screen_sender('email', ARRAY['stranger@gmail.com'])::text, v_known);
  PERFORM pg_temp.expect_value('a manager''s email tried on the WhatsApp channel',
    screen_sender('whatsapp', ARRAY['vikram.malhotra@meridian.example'])::text, v_known);
  PERFORM pg_temp.expect_value('Imran''s retired number', screen_sender('whatsapp',
    ARRAY[(SELECT c.value FROM meridian.user_contacts c JOIN meridian.users u ON u.id = c.user_id
            WHERE u.employee_code = 'REP-NDL-02' AND c.channel = 'whatsapp' AND c.valid_to IS NOT NULL)])::text, v_known);
  PERFORM pg_temp.expect_value('no contacts at all', screen_sender('email', ARRAY[]::text[])::text, v_known);
  PERFORM pg_temp.expect_value('NULL contacts', screen_sender('email', NULL)::text, v_known);
  PERFORM pg_temp.expect_value('a channel other than WhatsApp or email', screen_sender('dev', ARRAY['vikram.malhotra@meridian.example'])::text,
    '{"result": "bad_channel"}');
  PERFORM pg_temp.expect_value('SQL in the contact is just an unknown contact',
    screen_sender('email', ARRAY['x@y.example''); DROP TABLE meridian.orders; --'])::text, v_known);
  PERFORM pg_temp.expect_value('two contacts that belong to two people are refused like a stranger',
    screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NDL-01'), pg_temp.wa('REP-NDL-03')])::text, '{"result": "ambiguous_sender"}');
  PERFORM pg_temp.expect_value('a 21st contact is ignored (max 20 looked at)',
    screen_sender('whatsapp', array_fill('+910000000000'::text, ARRAY[20]) || pg_temp.wa('REP-NDL-01'))::text, v_known);
END $t$;

-- Deactivated staff and a number registered for the future: separate
-- statements, so each change is visible to the next.
UPDATE meridian.users SET is_active = false WHERE employee_code = 'REP-NDL-04';
INSERT INTO meridian.user_contacts (user_id, channel, value, valid_from)
SELECT id, 'email', 'future.joiner@meridian.example', app_now() + interval '2 days' FROM meridian.users WHERE employee_code = 'REP-NDL-05';

DO $t$
DECLARE v_before bigint;
BEGIN
  RAISE NOTICE '--- deactivated staff and not-yet-valid contacts ---';
  PERFORM pg_temp.expect_value('a deactivated rep is refused', screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NDL-04')])->>'result', 'unknown_sender');
  PERFORM pg_temp.expect_value('a contact valid only from the day after tomorrow is refused',
    screen_sender('email', ARRAY['future.joiner@meridian.example'])->>'result', 'unknown_sender');

  RAISE NOTICE '--- refusals are audited, at most once per sender per 10 minutes ---';
  PERFORM set_config('meridian.now', (now() + interval '1 day')::text, true);
  PERFORM screen_sender('whatsapp', ARRAY['+91 66666 00001']);
  PERFORM screen_sender('whatsapp', ARRAY['+916666600001']);
  PERFORM screen_sender('whatsapp', ARRAY['+91-66666-00001']);
  PERFORM pg_temp.expect_value('three messages in a row: one audit row', pg_temp.audits('unknown:+916666600001'), '1');
  PERFORM pg_temp.expect_value('the audit row records channel and reason only',
    (SELECT details::text FROM meridian.audit_log WHERE actor = 'unknown:+916666600001' ORDER BY id DESC LIMIT 1),
    '{"reason": "unknown_sender", "channel": "whatsapp", "contacts": 1}');
  PERFORM set_config('meridian.now', (now() + interval '1 day 11 minutes')::text, true);
  PERFORM screen_sender('whatsapp', ARRAY['+916666600001']);
  PERFORM pg_temp.expect_value('11 minutes later: a second audit row', pg_temp.audits('unknown:+916666600001'), '2');
  PERFORM screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NDL-01'), pg_temp.wa('REP-NDL-03')]);
  PERFORM pg_temp.expect_value('an ambiguous sender is audited with its reason',
    (SELECT details->>'reason' FROM meridian.audit_log WHERE action = 'identity.unknown_sender' ORDER BY id DESC LIMIT 1), 'ambiguous_sender');
  v_before := (SELECT count(*) FROM meridian.audit_log);
  PERFORM screen_sender('dev', ARRAY['someone@x.example']);
  PERFORM pg_temp.expect_value('a bad channel is not audited (the gate never sends one)',
    ((SELECT count(*) FROM meridian.audit_log) - v_before)::text, '0');
END $t$;

-- The Lua user a person wrote in as (for WhatsApp replies through Lua's test number).
DO $t$
DECLARE r record; v_nid bigint;
BEGIN
  RAISE NOTICE '--- lua_user_links: recorded from a verified sender only ---';
  PERFORM screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NOI-01')], 'user_lua_123');
  PERFORM pg_temp.expect_value('a verified rep''s Lua user is recorded for that channel',
    (SELECT lua_user_id FROM meridian.lua_user_links l JOIN meridian.users u ON u.id = l.user_id
      WHERE u.employee_code = 'REP-NOI-01' AND l.channel = 'whatsapp'), 'user_lua_123');
  PERFORM screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NOI-01')], 'user_lua_456');
  PERFORM pg_temp.expect_value('... and follows the latest one', (SELECT count(*) || '/' || max(lua_user_id) FROM meridian.lua_user_links), '1/user_lua_456');
  PERFORM screen_sender('whatsapp', ARRAY['+91 55555 00000'], 'user_stranger');
  PERFORM screen_sender('whatsapp', ARRAY[pg_temp.wa('REP-NOI-02')], 'x''); DROP TABLE meridian.orders; --');
  PERFORM pg_temp.expect_value('nothing for a stranger, nothing for a malformed id', (SELECT count(*)::text FROM meridian.lua_user_links), '1');
  INSERT INTO meridian.notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  VALUES ('order_status_to_rep', 'lua-link-check', (SELECT id FROM meridian.users WHERE employee_code = 'REP-NOI-01'), 'whatsapp',
          jsonb_build_object('order_id', 1, 'status', 'dispatched', 'chemist', jsonb_build_object('name', 'x')))
  RETURNING id INTO v_nid;
  SELECT * INTO r FROM claim_notifications(100, 120) c WHERE c.id = v_nid;
  PERFORM pg_temp.expect_value('a claimed WhatsApp notification carries that Lua user', r.lua_user_id, 'user_lua_456');
END $t$;

-- Reviewer registration (section 19).
DO $t$
DECLARE
  r jsonb;
  v_first_audit bigint := (SELECT coalesce(max(id), 0) FROM meridian.audit_log);   -- live registrations exist too
  v_ravi_email text := (SELECT c.value FROM meridian.user_contacts c JOIN meridian.users u ON u.id = c.user_id
                         WHERE u.employee_code = 'REP-NDL-01' AND c.channel = 'email' AND c.valid_to IS NULL);
BEGIN
  RAISE NOTICE '--- reviewer registration: own contacts onto the three demo people only ---';
  r := register_demo_contact('rep', 'whatsapp', '+91 70000 11111');
  PERFORM pg_temp.expect_value('register a number as the demo rep', r->>'status' || ' / ' || (r->>'as'), 'registered / Deepak Chauhan');
  PERFORM pg_temp.expect_value('... and it is now recognised as that rep',
    (SELECT result || '/' || role || '/' || full_name FROM identify_sender('whatsapp', ARRAY['+917000011111'])), 'ok/rep/Deepak Chauhan');
  PERFORM pg_temp.expect_value('... and gets past the identity gate', screen_sender('whatsapp', ARRAY['+917000011111'])->>'role', 'rep');
  PERFORM pg_temp.expect_value('the same again is idempotent', register_demo_contact('rep', 'whatsapp', '+917000011111')->>'status', 'already_registered');
  r := register_demo_contact('manager', 'whatsapp', '+917000011111');
  PERFORM pg_temp.expect_value('move the number to the demo manager', r->>'status' || ' / ' || (r->>'as'), 'moved / Kavita Srivastava');
  PERFORM pg_temp.expect_value('... now it is the manager, and only the manager',
    (SELECT result || '/' || role FROM identify_sender('whatsapp', ARRAY['+917000011111'])), 'ok/area_manager');
  PERFORM pg_temp.expect_value('... who manages the demo rep (approvals land here)',
    (SELECT m.employee_code FROM meridian.users r JOIN meridian.users m ON m.id = r.reports_to_id WHERE r.employee_code = 'REP-NOI-01'), 'ASM-NOI');
  r := register_demo_contact('regional_head', 'email', '  Reviewer.Head@Example.COM ');
  PERFORM pg_temp.expect_value('an email as the demo regional head (normalised)', r->>'status' || ' / ' || (r->>'as'), 'registered / Anjali Mehra');
  PERFORM pg_temp.expect_value('... who sees all teams',
    meridian_report('email', ARRAY['reviewer.head@example.com'], 'orders_summary', '{}')->>'scope', 'all teams');

  PERFORM register_demo_contact('manager', 'email', 'reviewer.manager@example.org');
  INSERT INTO meridian.notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  VALUES ('evening_summary', 'reviewer-contact-check', (SELECT id FROM meridian.users WHERE employee_code = 'ASM-NOI'), 'email', '{}');
  PERFORM pg_temp.expect_value('notifications go to the reviewer''s registered email, not the seeded one',
    (SELECT address FROM claim_notifications(100, 120) c WHERE c.kind = 'evening_summary' AND c.address LIKE '%example.org'), 'reviewer.manager@example.org');

  RAISE NOTICE '--- it never touches anyone else ---';
  PERFORM pg_temp.expect_value('a real rep''s email cannot be taken', register_demo_contact('manager', 'email', v_ravi_email)->>'error', 'taken');
  PERFORM pg_temp.expect_value('... nor removed', register_demo_contact(NULL, 'email', v_ravi_email, true)->>'error', 'taken');
  PERFORM pg_temp.expect_value('... Ravi is still Ravi',
    (SELECT full_name FROM identify_sender('email', ARRAY[v_ravi_email])), 'Ravi Kumar');
  PERFORM pg_temp.expect_value('only the three demo roles', register_demo_contact('admin', 'email', 'x@y.example')->>'error', 'bad_role');
  PERFORM pg_temp.expect_value('only WhatsApp or email', register_demo_contact('rep', 'sms', '+917000022222')->>'error', 'bad_channel');
  PERFORM pg_temp.expect_value('a malformed number is refused', register_demo_contact('rep', 'whatsapp', '12')->>'error', 'bad_contact');
  PERFORM pg_temp.expect_value('a malformed email is refused', register_demo_contact('rep', 'email', 'not an email')->>'error', 'bad_contact');
  PERFORM pg_temp.expect_value('SQL in the value is just a bad contact',
    register_demo_contact('rep', 'email', 'x''); DELETE FROM meridian.user_contacts; --')->>'error', 'bad_contact');

  RAISE NOTICE '--- removal ---';
  PERFORM pg_temp.expect_value('remove the number', register_demo_contact(NULL, 'whatsapp', '+917000011111', true)->>'status', 'removed');
  PERFORM pg_temp.expect_value('... it is a stranger again', screen_sender('whatsapp', ARRAY['+917000011111'])->>'result', 'unknown_sender');
  PERFORM pg_temp.expect_value('removing what is not registered', register_demo_contact(NULL, 'whatsapp', '+917000011111', true)->>'error', 'not_registered');
  PERFORM pg_temp.expect_value('every change is audited',
    (SELECT string_agg(action, ',' ORDER BY id) FROM meridian.audit_log WHERE actor = 'registration' AND id > v_first_audit),
    'identity.registered,identity.registered,identity.registered,identity.registered,identity.registration_refused,identity.registration_refused,identity.unregistered');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'identity checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% identity check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;

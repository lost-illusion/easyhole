// awg-client-defaults.mjs: give new wg-easy clients the server's AmneziaWG 3.x
// per-client values (ContentPaddingAddition, the timing ranges, DisableCookies).
//
// TEMPORARY WORKAROUND. wg-easy keeps new-client defaults only for Jc/Jmin/Jmax
// and I1-I5 (user_configs_table.default_*), so clients created in the admin UI get
// these 3.x options empty and their configs leave them out. Once wg-easy has its
// own defaults for them, remove this hack:
//     sudo ./awg-params.sh --remove-client-defaults
// awg-params.sh and this script print a notice when they detect upstream support.
//
// Installs an SQLite trigger that copies the values from the client's interface
// into every newly inserted client. Runs inside the wg-easy container from the
// wg0 PostUp hook (added by awg-params.sh), so the trigger is recreated on every
// interface start, e.g. after a wg-easy migration rebuilds clients_table.
import { DatabaseSync } from 'node:sqlite';

const TRIGGER = 'easyhole_awg_client_defaults';
const COLS = [
  'content_padding_addition',
  'rekey_after_time',
  'rekey_timeout',
  'reject_after_time',
  'keepalive_timeout',
  'max_handshake_attempts',
  'disable_cookies',
];

const db = new DatabaseSync(new URL('./wg-easy.db', import.meta.url).pathname);
db.exec('PRAGMA busy_timeout = 5000');

const defaults = db.prepare('PRAGMA table_info(user_configs_table)').all().map((c) => c.name);
if (defaults.includes('default_content_padding_addition')) {
  console.warn(
    `easyhole: wg-easy now has its own new-client defaults for the AmneziaWG 3.x options; ` +
      `${TRIGGER} is no longer needed. Run: sudo ./awg-params.sh --remove-client-defaults`,
  );
}

const sets = COLS.map(
  (c) => `${c} = COALESCE(NEW.${c}, (SELECT ${c} FROM interfaces_table WHERE name = NEW.interface_id))`,
).join(',\n    ');

db.exec(`
DROP TRIGGER IF EXISTS ${TRIGGER};
CREATE TRIGGER ${TRIGGER} AFTER INSERT ON clients_table
BEGIN
  UPDATE clients_table SET
    ${sets}
  WHERE id = NEW.id;
END;
`);
db.close();
console.log(`easyhole: ${TRIGGER} installed`);

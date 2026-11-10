// Indexes chosen from the queries in 04_queries.js. Without them, every query except
// lookups by _id reads the whole collection (COLLSCAN).
db = db.getSiblingDB('kolaro');

const t0 = Date.now();
const made = [
  // M1: support looks a customer up by email. Unique, as in PostgreSQL.
  db.customers.createIndex({ email: 1 }, { unique: true, name: 'customers_email' }),
  // M3: compliance lists tier-1 customers close to the tier-1 balance cap.
  db.customers.createIndex({ 'kyc.current_tier': 1, 'wallet.balance_kobo': -1 }, { name: 'customers_tier_balance' }),
  // M2: the newest bucket of one wallet's statement.
  db.statements.createIndex({ wallet_number: 1, month: -1, block: -1 }, { name: 'statements_wallet_month' }),
  // M4: all buckets for one month.
  db.statements.createIndex({ month: 1, wallet_type: 1 }, { name: 'statements_month_type' }),
  // M5: each $graphLookup step finds the transfers sent from a set of wallets.
  db.transfer_edges.createIndex({ from: 1 }, { name: 'edges_from' }),
  // M6: one customer's recent failed logins.
  db.audit_events.createIndex({ customer_id: 1, type: 1, at: -1 }, { name: 'events_customer_type_time' }),
  // Retention: MongoDB deletes each event automatically 180 days after its time.
  db.audit_events.createIndex({ at: 1 }, { expireAfterSeconds: 180 * 86400, name: 'events_ttl_180_days' }),
];
print('Built ' + made.length + ' indexes in ' + (Date.now() - t0) + ' ms');
for (const c of ['customers', 'statements', 'transfer_edges', 'audit_events']) {
  const sizes = db[c].stats({ indexDetails: false }).indexSizes;
  for (const [name, bytes] of Object.entries(sizes)) {
    print('  ' + c.padEnd(15) + name.padEnd(28) + (bytes / 1024).toFixed(0).padStart(7) + ' kB');
  }
}

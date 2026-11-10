// Six queries that serve real Kolaro operations. Run before and after 03_indexes.js;
// `phase` is set on the command line. For each query it prints the result, the plan
// MongoDB chose, how much it read, and the median time of 5 runs after a warm-up.
db = db.getSiblingDB('kolaro');

// Finds the first nested object with the given key in an explain() result.
function find(obj, key) {
  if (obj === null || typeof obj !== 'object') return undefined;
  if (key in obj) return obj[key];
  for (const v of Object.values(obj)) { const r = find(v, key); if (r !== undefined) return r; }
  return undefined;
}
function stages(plan) {
  const out = [];
  let p = plan && (plan.queryPlan || plan);
  while (p) {
    out.push(p.stage + (p.indexName ? '(' + p.indexName + ')' : ''));
    p = p.inputStage || (p.inputStages && p.inputStages[0]);
  }
  return out.join(' <- ');
}
function median(run) {
  const w = process.hrtime.bigint();
  run();  // warm-up
  const warm = Number(process.hrtime.bigint() - w) / 1e6;
  if (warm > 2000) return warm;  // too slow to repeat: report the single run
  const times = [];
  for (let i = 0; i < 5; i++) { const t = process.hrtime.bigint(); run(); times.push(Number(process.hrtime.bigint() - t) / 1e6); }
  times.sort((a, b) => a - b);
  return times[2];
}
function report(id, title, run, explain) {
  print('\n=== ' + id + '  ' + title + ' ===');
  const result = run();
  printjson(result);
  if (explain) {
    const e = explain();
    const stats = find(e, 'executionStats') || {};
    print('plan:          ' + stages(find(e, 'winningPlan')));
    print('keys examined: ' + stats.totalKeysExamined + ', documents examined: ' + stats.totalDocsExamined +
          ', returned: ' + stats.nReturned);
  }
  const ms = median(run);
  print((ms > 2000 ? 'single run:    ' : 'median time:   ') + ms.toFixed(3) + ' ms');
  results.push({ phase, id, ms });
}
const results = [];
print('Phase: ' + phase);

// M1. Support finds a customer by email.
const email = 'customer49994@customers.example';
report('M1', 'Customer profile by email, with wallet and KYC in one read',
  () => db.customers.findOne({ email }, { full_name: 1, phone: 1, wallet: 1, 'kyc.current_tier': 1 }),
  () => db.customers.find({ email }).explain('executionStats'));

// M2. The app's statement screen: the newest 50 entries of the busiest wallet.
const wallet = '1100000001';
report('M2', 'Latest 50 statement entries for wallet ' + wallet,
  () => {
    const b = db.statements.find({ wallet_number: wallet }, { month: 1, block: 1, closing_balance_kobo: 1, entries: { $slice: -50 } })
      .sort({ month: -1, block: -1 }).limit(1).toArray()[0];
    return { month: b.month, block: b.block, closing_balance_kobo: b.closing_balance_kobo,
             entries_returned: b.entries.length, newest_entry: b.entries[b.entries.length - 1] };
  },
  () => db.statements.find({ wallet_number: wallet }).sort({ month: -1, block: -1 }).limit(1).explain('executionStats'));

// M3. Compliance: tier-1 customers holding more than the tier-1 cap of N300,000.
// Portfolio 1 stores the caps but does not enforce them, so breaches can exist.
const overCap = { 'kyc.current_tier': 1, 'wallet.balance_kobo': { $gt: 30000000 } };
report('M3', 'Tier-1 customers over the N300,000 tier-1 balance cap',
  () => ({ customers: db.customers.countDocuments(overCap),
           top_3: db.customers.find(overCap, { _id: 1, 'wallet.balance_kobo': 1 }).sort({ 'wallet.balance_kobo': -1 }).limit(3).toArray() }),
  () => db.customers.find(overCap).sort({ 'wallet.balance_kobo': -1 }).explain('executionStats'));

// M4. Finance: customer spending by merchant category in October 2026.
const m4 = [
  { $match: { month: '2026-10', wallet_type: 'customer' } },
  { $unwind: '$entries' },
  { $match: { 'entries.amount_kobo': { $lt: 0 }, 'entries.counterparty.category': { $exists: true } } },
  { $group: { _id: '$entries.counterparty.category', payments: { $sum: 1 }, naira: { $sum: { $divide: [{ $multiply: ['$entries.amount_kobo', -1] }, 100] } } } },
  { $sort: { naira: -1 } },
];
report('M4', 'Customer spending by merchant category, October 2026 (aggregation pipeline)',
  () => db.statements.aggregate(m4).toArray(),
  () => db.statements.explain('executionStats').aggregate(m4));

// M5. Fraud: where did money from the busiest wallet go, up to three transfers away?
const m5 = [
  { $match: { from: wallet } },
  { $graphLookup: { from: 'transfer_edges', startWith: '$to', connectFromField: 'to', connectToField: 'from',
                    as: 'onward', maxDepth: 1, depthField: 'hop' } },
  { $unwind: '$onward' },
  { $group: { _id: { $add: ['$onward.hop', 2] }, transfers: { $sum: 1 }, wallets: { $addToSet: '$onward.to' } } },
  { $project: { _id: 0, hop: '$_id', transfers: 1, distinct_wallets_reached: { $size: '$wallets' } } },
  { $sort: { hop: 1 } },
];
report('M5', 'Money trail from wallet ' + wallet + ' in October, hops 2 and 3 ($graphLookup)',
  () => ({ first_hop_transfers: db.transfer_edges.countDocuments({ from: wallet }),
           onward: db.transfer_edges.aggregate(m5).toArray() }),
  () => db.transfer_edges.explain('executionStats').aggregate(m5));

// M6. Security: a customer's failed logins in the last 7 days.
const since = new Date('2026-11-03T00:00:00Z');
const busy = db.audit_events.aggregate([{ $match: { type: 'login', success: false, at: { $gte: since } } }, { $group: { _id: '$customer_id', n: { $sum: 1 } } }, { $sort: { n: -1, _id: 1 } }, { $limit: 1 }]).toArray()[0]._id;
const m6 = { customer_id: busy, type: 'login', success: false, at: { $gte: since } };
report('M6', 'Failed logins in the last 7 days for customer ' + busy,
  () => db.audit_events.find(m6, { _id: 0, at: 1, device: 1, ip: 1 }).sort({ at: -1 }).toArray(),
  () => db.audit_events.find(m6).sort({ at: -1 }).explain('executionStats'));

print('\nTIMINGS ' + JSON.stringify(results));

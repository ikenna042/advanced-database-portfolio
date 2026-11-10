// Writes: the validator rejecting bad documents, and an embedded update that changes
// a customer's KYC history in one atomic operation.
db = db.getSiblingDB('kolaro');

// Follows the server's validation report down to the rule that failed.
function why(e) {
  let node = e.errInfo && e.errInfo.details && e.errInfo.details.schemaRulesNotSatisfied &&
             e.errInfo.details.schemaRulesNotSatisfied[0];
  const path = [];
  while (node) {
    if (node.missingProperties) return 'missing ' + node.missingProperties.join(', ');
    if (node.reason) return (path.length ? path.join('.') + ': ' : '') + node.reason;
    if (node.propertiesNotSatisfied) {
      const p = node.propertiesNotSatisfied[0];
      path.push(p.propertyName);
      node = p.details && p.details[0];
    } else if (node.itemIndex !== undefined) {
      path.push('[' + node.itemIndex + ']');
      node = node.details && node.details[0];
    } else {
      node = node.details && node.details[0];
    }
  }
  return 'see errInfo';
}

function attempt(label, fn) {
  try { fn(); print('ACCEPTED  ' + label); }
  catch (e) { print('REJECTED  ' + label + '\n          ' + e.message + ' (code ' + e.code + '): ' + why(e)); }
}

print('=== W1  The validator enforces the document shape ===');
const good = db.customers.findOne({ _id: 2 });
attempt('Customer with no email', () => {
  const d = Object.assign({}, good, { _id: 900001 }); delete d.email; db.customers.insertOne(d);
});
attempt('Customer with an upper-case email', () =>
  db.customers.insertOne(Object.assign({}, good, { _id: 900002, email: 'Bravo2@Customers.example' })));
attempt('Customer with a non-Nigerian phone number', () =>
  db.customers.insertOne(Object.assign({}, good, { _id: 900003, email: 'x3@customers.example', phone: '+447700900123' })));
attempt('Wallet balance stored as a string', () =>
  db.customers.insertOne(Object.assign({}, good, { _id: 900004, email: 'x4@customers.example',
    wallet: Object.assign({}, good.wallet, { balance_kobo: '1000' }) })));
attempt('Statement bucket with 501 entries (cap is 500)', () => {
  const b = db.statements.findOne({ entry_count: 500 });
  b._id = 'test:overfull'; b.entries.push(b.entries[0]); b.entry_count = 501;
  db.statements.insertOne(b);
});
attempt('Audit event of an unknown type', () =>
  db.audit_events.insertOne({ customer_id: 1, type: 'password_change', at: new Date() }));
attempt('Audit event with extra, unplanned fields (allowed: only common fields are required)', () =>
  db.audit_events.insertOne({ customer_id: 1, type: 'login', at: new Date('2026-11-09T12:00:00Z'), success: true,
                              device: 'iphone-15', biometric: { method: 'face', confidence: 0.98 } }));

print('\n=== W2  One atomic update to an embedded array ===');
print('Customer 1 uploads a BVN to apply for tier 2. In PostgreSQL this is an INSERT into');
print('kyc_documents and another into kyc_reviews. Here it is one update to one document.');
const res = db.customers.updateOne(
  { _id: 1, 'kyc.documents.type': { $ne: 'bvn' } },
  { $push: { 'kyc.documents': { type: 'bvn', number: 'SYNTH-BVN-1', submitted_at: new Date('2026-11-10T09:00:00Z'),
                                reviews: [{ tier: 2, status: 'pending', submitted_at: new Date('2026-11-10T09:00:00Z') }] } } });
printjson({ matched: res.matchedCount, modified: res.modifiedCount });
print('Compliance approves it: the positional operators find the right array elements.');
const ok = db.customers.updateOne(
  { _id: 1 },
  { $set: { 'kyc.documents.$[d].reviews.$[r].status': 'approved',
            'kyc.documents.$[d].reviews.$[r].reviewed_by_staff_id': 2,
            'kyc.documents.$[d].reviews.$[r].reviewed_at': new Date('2026-11-10T10:00:00Z'),
            'kyc.current_tier': 2 } },
  { arrayFilters: [{ 'd.type': 'bvn' }, { 'r.status': 'pending', 'r.tier': 2 }] });
printjson({ matched: ok.matchedCount, modified: ok.modifiedCount });
printjson(db.customers.findOne({ _id: 1 }, { _id: 0, full_name: 1, kyc: 1 }));
print('Running the upload again matches nothing, because the filter requires no BVN yet:');
printjson({ matched: db.customers.updateOne({ _id: 1, 'kyc.documents.type': { $ne: 'bvn' } }, { $set: { x: 1 } }).matchedCount });

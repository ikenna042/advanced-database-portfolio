// Generates 50,000 audit events over the 30 days before 10 November 2026.
// Each event type has its own fields, which is awkward in one relational table
// (Portfolio 1 used a JSONB column) but natural in a document collection.
db = db.getSiblingDB('kolaro');

let seed = 42;  // a fixed seed (Park-Miller generator), so every run generates the same events
const rand = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
const pick = (list) => list[Math.floor(rand() * list.length)];

const end = new Date('2026-11-10T00:00:00Z').getTime();
const devices = ['android-pixel-7', 'android-tecno-spark', 'iphone-13', 'iphone-15', 'android-infinix-hot'];
const events = [];
for (let i = 0; i < 50000; i++) {
  // Squaring the random number makes a few customers far more active, as in Portfolio 2.
  const customer_id = 4 + Math.floor(rand() * rand() * 100000);
  const at = new Date(end - Math.floor(rand() * 30 * 86400000));
  const r = rand();
  let e;
  if (r < 0.70) {
    e = { type: 'login', success: rand() > 0.08, device: pick(devices), ip: '10.0.' + Math.floor(rand() * 255) + '.' + Math.floor(rand() * 255) };
  } else if (r < 0.80) {
    e = { type: 'device_change', from_device: pick(devices), to_device: pick(devices), confirmed_by: pick(['otp', 'email']) };
  } else if (r < 0.88) {
    e = { type: 'kyc_upload', document_type: pick(['bvn', 'nin', 'passport']), file: { pages: 1 + Math.floor(rand() * 3), size_kb: 200 + Math.floor(rand() * 2000) } };
  } else if (r < 0.95) {
    e = { type: 'pin_reset', channel: pick(['app', 'ussd', 'support']) };
  } else {
    e = { type: 'limit_change', from_kobo: 5000000, to_kobo: pick([10000000, 20000000]), approved_by_staff_id: 2 };
  }
  events.push(Object.assign({ customer_id, at }, e));
}
db.audit_events.insertMany(events, { ordered: false });

print('audit_events: ' + db.audit_events.countDocuments() + ' documents');
printjson(db.audit_events.aggregate([
  { $group: { _id: '$type', events: { $sum: 1 } } }, { $sort: { events: -1 } },
]).toArray());
print('Two events of different types, as stored:');
printjson(db.audit_events.find({ type: 'login' }, { _id: 0 }).limit(1).toArray());
printjson(db.audit_events.find({ type: 'kyc_upload' }, { _id: 0 }).limit(1).toArray());

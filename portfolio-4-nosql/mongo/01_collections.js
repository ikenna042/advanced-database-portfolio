// Recreates the kolaro database with a JSON Schema validator on each collection.
// MongoDB is schema-flexible, but not schema-less: the validator rejects documents
// that break the rules the application relies on.
db = db.getSiblingDB('kolaro');
db.dropDatabase();

const date = { bsonType: 'date' };
const kobo = { bsonType: ['int', 'long'] };

db.createCollection('customers', {
  validator: { $jsonSchema: {
    bsonType: 'object',
    required: ['_id', 'full_name', 'email', 'phone', 'status', 'wallet', 'kyc'],
    properties: {
      email: { bsonType: 'string', pattern: '^[^A-Z]+@[^A-Z]+$', description: 'stored in lower case' },
      phone: { bsonType: 'string', pattern: '^\\+234[0-9]{10}$' },
      status: { enum: ['active', 'suspended', 'closed'] },
      wallet: {
        bsonType: 'object',
        required: ['wallet_number', 'status', 'balance_kobo'],
        properties: {
          wallet_number: { bsonType: 'string', pattern: '^[0-9]{10}$' },
          status: { enum: ['active', 'frozen', 'closed'] },
          balance_kobo: kobo,
        },
      },
      kyc: {
        bsonType: 'object',
        required: ['current_tier', 'documents'],
        properties: {
          current_tier: { bsonType: 'int', minimum: 0, maximum: 3 },
          documents: { bsonType: 'array', items: {
            bsonType: 'object', required: ['type', 'number', 'reviews'],
            properties: {
              type: { enum: ['bvn', 'nin', 'passport', 'drivers_licence'] },
              reviews: { bsonType: 'array', items: {
                bsonType: 'object', required: ['tier', 'status'],
                properties: { status: { enum: ['pending', 'approved', 'rejected'] } },
              } },
            },
          } },
        },
      },
    },
  } },
});

db.createCollection('statements', {
  validator: { $jsonSchema: {
    bsonType: 'object',
    required: ['wallet_number', 'month', 'block', 'entry_count', 'entries'],
    properties: {
      month: { bsonType: 'string', pattern: '^[0-9]{4}-[0-9]{2}$' },
      entry_count: { bsonType: 'int', minimum: 1, maximum: 500 },
      entries: { bsonType: 'array', maxItems: 500, items: {
        bsonType: 'object',
        required: ['entry_id', 'at', 'amount_kobo', 'balance_after_kobo', 'type'],
        properties: { at: date, amount_kobo: kobo, balance_after_kobo: kobo,
                      type: { enum: ['deposit', 'withdrawal', 'transfer', 'reversal'] } },
      } },
    },
  } },
});

db.createCollection('transfer_edges', {
  validator: { $jsonSchema: {
    bsonType: 'object', required: ['from', 'to', 'amount_kobo', 'at'],
    properties: { amount_kobo: kobo, at: date },
  } },
});

// Events have different shapes per type. Only the common fields are required.
db.createCollection('audit_events', {
  validator: { $jsonSchema: {
    bsonType: 'object', required: ['customer_id', 'type', 'at'],
    properties: {
      type: { enum: ['login', 'device_change', 'kyc_upload', 'pin_reset', 'limit_change'] },
      at: date,
    },
  } },
});

// Daily spending counters, used by the atomic update demonstration.
db.createCollection('daily_spend');

print('Collections: ' + db.getCollectionNames().sort().join(', '));

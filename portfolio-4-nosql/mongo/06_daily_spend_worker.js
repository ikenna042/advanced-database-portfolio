// One worker in the daily spending limit test. run.sh starts 10 of these at once.
// Each sends 5 payment requests of N2,000 against a daily limit of N50,000, so only
// 25 of the 50 requests can be approved. `mode` and `worker` are set on the command line.
db = db.getSiblingDB('kolaro');
const key = 'limit-test:' + mode;
const amount = 200000;

for (let i = 0; i < 5; i++) {
  const request = 'w' + worker + '-r' + i;
  if (mode === 'naive') {
    // Read, decide in the application, then write back an absolute value.
    const doc = db.daily_spend.findOne({ _id: key });
    sleep(20);  // the application's own processing time between read and write
    if (doc.spent_kobo + amount <= doc.limit_kobo) {
      db.daily_spend.updateOne({ _id: key }, { $set: { spent_kobo: doc.spent_kobo + amount }, $push: { approved: request } });
    }
  } else {
    // The check and the change are one atomic operation on one document.
    sleep(20);
    db.daily_spend.updateOne(
      { _id: key, $expr: { $lte: [{ $add: ['$spent_kobo', amount] }, '$limit_kobo'] } },
      { $inc: { spent_kobo: amount }, $push: { approved: request } });
  }
}

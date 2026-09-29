import { resolve } from 'node:path';
import { migrateLocalDatabase } from './database.mjs';

const source = resolve(process.env.LOCAL_DB_PATH || 'api/data.json');
try {
  const totals = await migrateLocalDatabase(source);
  console.log(`Migration complete: ${totals.users} users, ${totals.barbers} barbers, ${totals.bookings} bookings.`);
} catch (error) {
  console.error(`Migration failed: ${error.message}`);
  process.exitCode = 1;
}

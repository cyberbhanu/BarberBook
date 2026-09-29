import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const table = 'barberbook_state';
const stateKey = 'main';

function supabaseConfig() {
  const url = process.env.SUPABASE_URL?.trim().replace(/\/+$/, '');
  const secretKey = process.env.SUPABASE_SECRET_KEY?.trim();
  const legacyServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (secretKey && legacyServiceKey) {
    throw new Error('Set SUPABASE_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY, not both.');
  }
  const key = secretKey || legacyServiceKey;
  if (Boolean(url) !== Boolean(key)) {
    throw new Error('Set SUPABASE_URL and SUPABASE_SECRET_KEY, or leave both unset for local JSON storage.');
  }
  return url && key ? { url, key, usesLegacyJwt: Boolean(legacyServiceKey) } : null;
}

async function requestSupabase(path, options = {}) {
  const config = supabaseConfig();
  if (!config) throw new Error('Supabase credentials are not configured.');
  const response = await fetch(`${config.url}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: config.key,
      ...(config.usesLegacyJwt ? { Authorization: `Bearer ${config.key}` } : {}),
      'Content-Type': 'application/json',
      ...options.headers,
    },
    signal: AbortSignal.timeout(15000),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Supabase request failed (${response.status}): ${body || response.statusText}`);
  }
  return body ? JSON.parse(body) : null;
}

function stateUrl() {
  const query = new URLSearchParams({ select: 'payload', key: `eq.${stateKey}` });
  return `${table}?${query}`;
}

export async function loadDatabase(localPath) {
  if (!supabaseConfig()) {
    try {
      return JSON.parse(await readFile(localPath, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return { users: [], barbers: [], bookings: [], reviews: [] };
    }
  }
  const rows = await requestSupabase(stateUrl());
  return rows?.[0]?.payload ?? { users: [], barbers: [], bookings: [], reviews: [] };
}

export async function saveDatabase(database, localPath) {
  const config = supabaseConfig();
  if (!config) {
    await mkdir(dirname(localPath), { recursive: true });
    const temp = `${localPath}.tmp`;
    await writeFile(temp, JSON.stringify(database, null, 2), 'utf8');
    const { rename } = await import('node:fs/promises');
    await rename(temp, localPath);
    return;
  }
  const query = new URLSearchParams({ on_conflict: 'key' });
  await requestSupabase(`${table}?${query}`, {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({ key: stateKey, payload: database, updated_at: new Date().toISOString() }),
  });
}

export async function migrateLocalDatabase(localPath) {
  if (!supabaseConfig()) throw new Error('Set SUPABASE_URL and SUPABASE_SECRET_KEY before migrating.');
  const database = JSON.parse(await readFile(resolve(localPath), 'utf8'));
  const rows = await requestSupabase(stateUrl());
  if (rows?.length) throw new Error('Supabase already has BarberBook data. Migration stopped without changing it.');
  await requestSupabase(table, {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ key: stateKey, payload: database, updated_at: new Date().toISOString() }),
  });
  return { users: database.users?.length ?? 0, barbers: database.barbers?.length ?? 0, bookings: database.bookings?.length ?? 0 };
}

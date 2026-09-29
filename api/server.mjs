import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { randomBytes, randomUUID, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { loadDatabase, saveDatabase } from './database.mjs';

const scrypt = promisify(scryptCallback);
const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || '0.0.0.0';
const dbPath = resolve(process.env.BARBERBOOK_DB || 'api/data.json');
const sessions = new Map();
const seedServices = [
  { id: 'haircut', name: 'Haircut', price: 150, duration: 30, enabled: true },
  { id: 'beard', name: 'Beard trim', price: 100, duration: 20, enabled: true },
  { id: 'combo', name: 'Haircut + Beard', price: 220, duration: 45, enabled: true },
  { id: 'facial', name: 'Facial', price: 300, duration: 40, enabled: true },
];
let db;
let writeQueue = Promise.resolve();

async function save() {
  writeQueue = writeQueue.catch(() => {}).then(() => saveDatabase(db, dbPath));
  return writeQueue;
}
async function hashPassword(password, salt = randomBytes(16).toString('hex')) {
  const derived = await scrypt(password, salt, 64);
  return { salt, hash: Buffer.from(derived).toString('hex') };
}
async function verifyPassword(password, saved) {
  const actual = await hashPassword(password, saved.salt);
  const a = Buffer.from(actual.hash, 'hex');
  const b = Buffer.from(saved.hash, 'hex');
  return a.length === b.length && timingSafeEqual(a, b);
}
function publicBarber(barber) {
  const owner = db.users.find((u) => u.id === barber.ownerId);
  return { id: barber.id, ownerId: barber.ownerId, ownerName: owner?.name ?? '', shop: barber.shop,
    address: barber.address, phone: owner?.phone ?? '', status: barber.status, rating: barber.rating ?? 5,
    services: barber.services, availability: barber.availability, createdAt: barber.createdAt };
}
function safeUser(user) { return { id: user.id, name: user.name, email: user.email, phone: user.phone, role: user.role, status: user.status }; }
function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS', 'Access-Control-Allow-Private-Network': 'true' });
  res.end(JSON.stringify(body));
}
async function body(req) {
  let data = '';
  for await (const chunk of req) { data += chunk; if (data.length > 1024 * 1024) throw new Error('Request too large.'); }
  return data ? JSON.parse(data) : {};
}
function requireAuth(req, roles = []) {
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const session = sessions.get(token);
  if (!session || session.expiresAt < Date.now()) { if (token) sessions.delete(token); throw Object.assign(new Error('Please sign in again.'), { status: 401 }); }
  const user = db.users.find((u) => u.id === session.userId);
  if (!user) throw Object.assign(new Error('Account not found.'), { status: 401 });
  if (user.role === 'barber' && user.status === 'pending') throw Object.assign(new Error('Your shop application is awaiting admin approval.'), { status: 403 });
  if (user.role === 'barber' && user.status === 'rejected') throw Object.assign(new Error('Your shop application was declined. Please contact BarberBook support.'), { status: 403 });
  if (roles.length && !roles.includes(user.role)) throw Object.assign(new Error('You do not have permission to perform this action.'), { status: 403 });
  return user;
}
function required(value, label) {
  if (typeof value !== 'string' || !value.trim()) throw Object.assign(new Error(`${label} is required.`), { status: 400 });
  return value.trim();
}
function userByEmail(email) { return db.users.find((u) => u.email === String(email || '').trim().toLowerCase()); }
function createBarberProfile(user, input, status) {
  const barber = { id: randomUUID(), ownerId: user.id, shop: required(input.shop, 'Shop name'),
    address: String(input.address || '').trim(), status, rating: 5, services: seedServices.map((s) => ({ ...s })),
    availability: { Monday: true, Tuesday: true, Wednesday: true, Thursday: true, Friday: true, Saturday: true, Sunday: false }, createdAt: new Date().toISOString() };
  user.status = status;
  db.barbers.push(barber);
  return barber;
}

async function route(req, res) {
  if (req.method === 'OPTIONS') return json(res, 204, {});
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const path = url.pathname;
  const input = ['POST', 'PATCH', 'PUT'].includes(req.method) ? await body(req) : {};

  if (req.method === 'GET' && path === '/health') return json(res, 200, { ok: true, service: 'BarberBook API' });
  if (req.method === 'POST' && path === '/auth/register') {
    const role = input.role || 'customer';
    if (!['customer', 'barber'].includes(role)) throw Object.assign(new Error('Choose customer or barber registration.'), { status: 400 });
    const email = required(input.email, 'Email').toLowerCase();
    if (!/^\S+@\S+\.\S+$/.test(email)) throw Object.assign(new Error('Enter a valid email address.'), { status: 400 });
    if (userByEmail(email)) throw Object.assign(new Error('An account with this email already exists.'), { status: 409 });
    if (typeof input.password !== 'string' || input.password.length < 8) throw Object.assign(new Error('Password must be at least 8 characters.'), { status: 400 });
    if (role === 'barber') required(input.shop, 'Shop name');
    const password = await hashPassword(input.password);
    const user = { id: randomUUID(), name: required(input.name, 'Name'), email, phone: String(input.phone || '').trim(), role,
      status: role === 'barber' ? 'pending' : 'active', password, createdAt: new Date().toISOString() };
    db.users.push(user);
    let barber;
    if (role === 'barber') barber = createBarberProfile(user, input, 'pending');
    await save();
    return json(res, 201, { message: role === 'barber' ? 'Application submitted. You can sign in after an admin approves your shop.' : 'Account created. Please sign in.', user: safeUser(user), barber: barber && publicBarber(barber) });
  }
  if (req.method === 'POST' && path === '/auth/login') {
    const user = userByEmail(input.email);
    if (!user || !(await verifyPassword(String(input.password || ''), user.password))) throw Object.assign(new Error('Email or password is incorrect.'), { status: 401 });
    if (user.role === 'barber' && user.status === 'pending') throw Object.assign(new Error('Your shop application is pending admin approval.'), { status: 403 });
    if (user.role === 'barber' && user.status === 'rejected') throw Object.assign(new Error('Your shop application was declined. Please contact BarberBook support.'), { status: 403 });
    const token = randomBytes(32).toString('base64url');
    sessions.set(token, { userId: user.id, expiresAt: Date.now() + 12 * 60 * 60 * 1000 });
    return json(res, 200, { token, user: safeUser(user) });
  }
  if (req.method === 'POST' && path === '/auth/logout') {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, ''); sessions.delete(token);
    return json(res, 200, { ok: true });
  }
  if (req.method === 'POST' && path === '/auth/change-password') {
    const user = requireAuth(req);
    if (!(await verifyPassword(String(input.currentPassword || ''), user.password))) throw Object.assign(new Error('Current password is incorrect.'), { status: 401 });
    if (typeof input.newPassword !== 'string' || input.newPassword.length < 8) throw Object.assign(new Error('New password must be at least 8 characters.'), { status: 400 });
    user.password = await hashPassword(input.newPassword); await save();
    return json(res, 200, { ok: true });
  }
  if (req.method === 'GET' && path === '/barbers') return json(res, 200, { barbers: db.barbers.filter((b) => b.status === 'approved').map(publicBarber) });
  if (req.method === 'GET' && path.startsWith('/barbers/')) {
    const barber = db.barbers.find((b) => b.id === path.split('/')[2] && b.status === 'approved');
    if (!barber) throw Object.assign(new Error('Barber not found.'), { status: 404 });
    return json(res, 200, { barber: publicBarber(barber) });
  }

  if (path === '/me' && req.method === 'GET') {
    const user = requireAuth(req);
    const barber = db.barbers.find((b) => b.ownerId === user.id);
    return json(res, 200, { user: { ...safeUser(user), favoriteBarberIds: user.favoriteBarberIds ?? [] }, barber: barber ? publicBarber(barber) : null });
  }
  if (path === '/me' && req.method === 'PATCH') {
    const user = requireAuth(req);
    if (input.name != null) user.name = required(input.name, 'Name');
    if (input.phone != null) user.phone = String(input.phone).trim();
    if (input.favoriteBarberIds != null) {
      if (!Array.isArray(input.favoriteBarberIds)) throw Object.assign(new Error('Favorites must be a list of barbers.'), { status: 400 });
      const approvedIds = new Set(db.barbers.filter((b) => b.status === 'approved').map((b) => b.id));
      user.favoriteBarberIds = [...new Set(input.favoriteBarberIds.filter((id) => typeof id === 'string' && approvedIds.has(id)))];
    }
    await save();
    return json(res, 200, { user: { ...safeUser(user), favoriteBarberIds: user.favoriteBarberIds ?? [] } });
  }
  if (path === '/admin/overview' && req.method === 'GET') {
    requireAuth(req, ['admin']);
    return json(res, 200, { customers: db.users.filter((u) => u.role === 'customer').length, barbers: db.barbers.filter((b) => b.status === 'approved').length,
      pendingApplications: db.barbers.filter((b) => b.status === 'pending').length, bookings: db.bookings.length,
      revenue: db.bookings.filter((b) => b.status === 'completed').reduce((n, b) => n + b.total, 0) });
  }
  if (path === '/admin/barbers' && req.method === 'GET') {
    requireAuth(req, ['admin']);
    return json(res, 200, { barbers: db.barbers.map((barber) => ({ ...publicBarber(barber), email: db.users.find((user) => user.id === barber.ownerId)?.email ?? '' })) });
  }
  if (path === '/admin/barbers' && req.method === 'POST') {
    requireAuth(req, ['admin']);
    const email = required(input.email, 'Email').toLowerCase();
    if (!/^\S+@\S+\.\S+$/.test(email)) throw Object.assign(new Error('Enter a valid email address.'), { status: 400 });
    if (userByEmail(email)) throw Object.assign(new Error('An account with this email already exists.'), { status: 409 });
    if (typeof input.password !== 'string' || input.password.length < 8) throw Object.assign(new Error('Password must be at least 8 characters.'), { status: 400 });
    required(input.shop, 'Shop name');
    const user = { id: randomUUID(), name: required(input.name, 'Barber name'), email, phone: String(input.phone || '').trim(), role: 'barber', status: 'approved', password: await hashPassword(input.password), createdAt: new Date().toISOString() };
    db.users.push(user);
    const barber = createBarberProfile(user, input, 'approved');
    await save();
    return json(res, 201, { user: safeUser(user), barber: publicBarber(barber) });
  }
  const barberEdit = path.match(/^\/admin\/barbers\/([^/]+)$/);
  if (barberEdit && req.method === 'PATCH') {
    requireAuth(req, ['admin']);
    const barber = db.barbers.find((item) => item.id === barberEdit[1]);
    if (!barber) throw Object.assign(new Error('Barber not found.'), { status: 404 });
    const owner = db.users.find((item) => item.id === barber.ownerId);
    if (!owner) throw Object.assign(new Error('Barber account not found.'), { status: 404 });
    if (input.ownerName != null) owner.name = required(input.ownerName, 'Barber name');
    if (input.shop != null) barber.shop = required(input.shop, 'Shop name');
    if (input.phone != null) owner.phone = String(input.phone).trim();
    if (input.address != null) barber.address = String(input.address).trim();
    if (input.email != null) {
      const email = required(input.email, 'Email').toLowerCase();
      if (!/^\S+@\S+\.\S+$/.test(email)) throw Object.assign(new Error('Enter a valid email address.'), { status: 400 });
      const duplicate = userByEmail(email);
      if (duplicate && duplicate.id !== owner.id) throw Object.assign(new Error('An account with this email already exists.'), { status: 409 });
      owner.email = email;
    }
    await save();
    return json(res, 200, { barber: publicBarber(barber) });
  }
  const review = path.match(/^\/admin\/barbers\/([^/]+)\/(approve|reject)$/);
  if (review && req.method === 'POST') {
    requireAuth(req, ['admin']);
    const barber = db.barbers.find((b) => b.id === review[1]);
    if (!barber) throw Object.assign(new Error('Application not found.'), { status: 404 });
    barber.status = review[2] === 'approve' ? 'approved' : 'rejected';
    const owner = db.users.find((u) => u.id === barber.ownerId);
    if (owner) owner.status = barber.status;
    await save();
    return json(res, 200, { barber: publicBarber(barber) });
  }

  if (path === '/bookings' && req.method === 'GET') {
    const user = requireAuth(req);
    let rows;
    if (user.role === 'admin') rows = db.bookings;
    else if (user.role === 'barber') { const profile = db.barbers.find((b) => b.ownerId === user.id); rows = db.bookings.filter((b) => b.barberId === profile?.id); }
    else rows = db.bookings.filter((b) => b.customerId === user.id);
    return json(res, 200, { bookings: rows.map((b) => ({ ...b, customer: safeUser(db.users.find((u) => u.id === b.customerId)), barber: publicBarber(db.barbers.find((p) => p.id === b.barberId)) })) });
  }
  if (path === '/reviews' && req.method === 'GET') {
    const user = requireAuth(req);
    const rows = db.reviews.filter((review) => user.role === 'admin' ||
      (user.role === 'customer' && review.customerId === user.id) ||
      (user.role === 'barber' && db.barbers.some((barber) => barber.id === review.barberId && barber.ownerId === user.id)));
    return json(res, 200, { reviews: rows.map((review) => ({ ...review,
      customer: safeUser(db.users.find((item) => item.id === review.customerId)),
      barber: publicBarber(db.barbers.find((item) => item.id === review.barberId)) })) });
  }
  if (path === '/reviews' && req.method === 'POST') {
    const user = requireAuth(req, ['customer']);
    const bookingId = required(input.bookingId, 'Booking');
    const booking = db.bookings.find((item) => item.id === bookingId && item.customerId === user.id && item.status === 'completed');
    if (!booking) throw Object.assign(new Error('You can review a completed appointment only.'), { status: 400 });
    if (db.reviews.some((review) => review.bookingId === booking.id)) throw Object.assign(new Error('This appointment already has a review.'), { status: 409 });
    const rating = Number(input.rating);
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) throw Object.assign(new Error('Choose a rating from 1 to 5 stars.'), { status: 400 });
    const review = { id: randomUUID(), customerId: user.id, barberId: booking.barberId, bookingId: booking.id,
      rating, comment: String(input.comment || '').trim().slice(0, 1000), createdAt: new Date().toISOString() };
    db.reviews.push(review);
    const barber = db.barbers.find((item) => item.id === booking.barberId);
    if (barber) barber.rating = Math.round(db.reviews.filter((item) => item.barberId === barber.id).reduce((sum, item) => sum + item.rating, 0) / db.reviews.filter((item) => item.barberId === barber.id).length * 10) / 10;
    await save();
    return json(res, 201, { review });
  }
  if (path === '/bookings' && req.method === 'POST') {
    const user = requireAuth(req, ['customer']);
    const barber = db.barbers.find((b) => b.id === input.barberId && b.status === 'approved');
    if (!barber) throw Object.assign(new Error('This barber is not available for booking.'), { status: 404 });
    const service = barber.services.find((s) => s.id === input.serviceId && s.enabled);
    if (!service) throw Object.assign(new Error('Choose an available service.'), { status: 400 });
    const date = required(input.date, 'Date'); const time = required(input.time, 'Time');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !Number.isFinite(Date.parse(`${date}T00:00:00Z`))) throw Object.assign(new Error('Choose a valid appointment date.'), { status: 400 });
    if (date < new Date().toISOString().slice(0, 10)) throw Object.assign(new Error('Appointment date must be today or later.'), { status: 400 });
    const weekday = new Date(`${date}T00:00:00Z`).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
    if (!barber.availability[weekday]) throw Object.assign(new Error('This shop is closed on the selected day.'), { status: 400 });
    const clock = time.match(/^(\d{1,2}):(\d{2}) (AM|PM)$/i);
    if (!clock) throw Object.assign(new Error('Choose one of the available time slots.'), { status: 400 });
    let hour = Number(clock[1]) % 12; if (clock[3].toUpperCase() === 'PM') hour += 12;
    const appointmentAt = new Date(`${date}T00:00:00`); appointmentAt.setHours(hour, Number(clock[2]), 0, 0);
    if (appointmentAt <= new Date()) throw Object.assign(new Error('Choose a future appointment time.'), { status: 400 });
    const conflict = db.bookings.some((b) => b.barberId === barber.id && b.date === date && b.time === time && !['cancelled', 'rejected'].includes(b.status));
    if (conflict) throw Object.assign(new Error('That time has just been booked. Please choose another slot.'), { status: 409 });
    const booking = { id: randomUUID(), reference: `BB-${Date.now().toString().slice(-8)}`, customerId: user.id, barberId: barber.id,
      serviceId: service.id, service: service.name, total: service.price, duration: service.duration, date, time, status: 'pending', createdAt: new Date().toISOString() };
    db.bookings.push(booking); await save(); return json(res, 201, { booking });
  }
  const bookingAction = path.match(/^\/bookings\/([^/]+)\/(accept|reject|complete|cancel)$/);
  if (bookingAction && req.method === 'POST') {
    const user = requireAuth(req); const booking = db.bookings.find((b) => b.id === bookingAction[1]);
    if (!booking) throw Object.assign(new Error('Booking not found.'), { status: 404 });
    if (user.role === 'barber') { const profile = db.barbers.find((b) => b.ownerId === user.id); if (booking.barberId !== profile?.id) throw Object.assign(new Error('This booking belongs to another shop.'), { status: 403 }); }
    else if (user.role === 'customer' && booking.customerId !== user.id) throw Object.assign(new Error('This booking belongs to another customer.'), { status: 403 });
    else if (user.role === 'customer' && bookingAction[2] !== 'cancel') throw Object.assign(new Error('Customers can only cancel their own appointments.'), { status: 403 });
    const status = { accept: 'confirmed', reject: 'rejected', complete: 'completed', cancel: 'cancelled' }[bookingAction[2]];
    booking.status = status; booking.updatedAt = new Date().toISOString(); await save(); return json(res, 200, { booking });
  }
  if (path === '/barber/services' && req.method === 'GET') {
    const user = requireAuth(req, ['barber']); const barber = db.barbers.find((b) => b.ownerId === user.id);
    return json(res, 200, { services: barber?.services ?? [] });
  }
  if (path === '/barber/services' && req.method === 'POST') {
    const user = requireAuth(req, ['barber']); const barber = db.barbers.find((b) => b.ownerId === user.id);
    const service = { id: randomUUID(), name: required(input.name, 'Service name'), price: Math.max(0, Number(input.price)), duration: Math.max(5, Number(input.duration) || 30), enabled: true };
    barber.services.push(service); await save(); return json(res, 201, { service });
  }
  const serviceRoute = path.match(/^\/barber\/services\/([^/]+)$/);
  if (serviceRoute && req.method === 'PATCH') {
    const user = requireAuth(req, ['barber']); const barber = db.barbers.find((b) => b.ownerId === user.id);
    const service = barber?.services.find((s) => s.id === serviceRoute[1]);
    if (!service) throw Object.assign(new Error('Service not found.'), { status: 404 });
    if (input.price != null) service.price = Math.max(0, Number(input.price));
    if (input.duration != null) service.duration = Math.max(5, Number(input.duration));
    if (input.enabled != null) service.enabled = Boolean(input.enabled);
    await save(); return json(res, 200, { service });
  }
  if (path === '/barber/availability' && req.method === 'PATCH') {
    const user = requireAuth(req, ['barber']); const barber = db.barbers.find((b) => b.ownerId === user.id);
    const day = required(input.day, 'Day');
    if (!(day in barber.availability)) throw Object.assign(new Error('Choose a valid weekday.'), { status: 400 });
    barber.availability[day] = Boolean(input.enabled); await save(); return json(res, 200, { availability: barber.availability });
  }

  return json(res, 404, { error: 'Route not found.' });
}

async function main() {
  db = await loadDatabase(dbPath);
  if (!Array.isArray(db.reviews)) db.reviews = [];
  if (!db.users.some((u) => u.role === 'admin')) {
    const email = process.env.ADMIN_EMAIL || 'admin@barberbook.com';
    const password = process.env.ADMIN_PASSWORD || randomBytes(24).toString('base64url');
    const user = { id: randomUUID(), name: 'BarberBook Admin', email, phone: '', role: 'admin', status: 'active', password: await hashPassword(password), createdAt: new Date().toISOString() };
    db.users.push(user); await save();
    console.log(`Initial admin created: ${email}`);
    if (!process.env.ADMIN_PASSWORD) console.log(`Generated one-time bootstrap password: ${password}`);
  }
  createServer((req, res) => route(req, res).catch((error) => {
    console.error(error);
    if (!res.headersSent) json(res, error.status || 500, { error: error.status ? error.message : 'The server could not complete the request.' });
  })).listen(port, host, () => console.log(`BarberBook API listening at http://${host}:${port}`));
}
main().catch((e) => { console.error(e); process.exitCode = 1; });

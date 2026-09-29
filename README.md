# BarberBook

Flutter booking app with a local Node API for accounts, barber approval, services, and appointments.

## Run on this computer

Open two PowerShell terminals in the project folder.

Terminal 1 starts the API. Set an admin password before the first launch, or let the API generate a one-time password and print it to the terminal:

```powershell
$env:ADMIN_PASSWORD = 'choose-a-private-password'
node api/server.mjs
```

The initial admin email is `admin@barberbook.com`. The API saves account and booking data to `api/data.json` and listens on port `8787`. You can change the admin password from the app after signing in.

Terminal 2 runs Flutter Web:

```powershell
flutter pub get
flutter run -d chrome
```

## Run on Android

Install Android Studio and its Android SDK, then create or start an Android emulator. With the API running in Terminal 1:

```powershell
flutter run -d android
```

The Android emulator connects to the API at `http://10.0.2.2:8787` automatically. To install on a physical Android phone, connect both devices to the same trusted Wi-Fi network, find this computer's local IPv4 address, and start Flutter with that address:

```powershell
flutter run -d <phone-device-id> --dart-define=API_BASE_URL=http://<computer-ipv4>:8787
```

Allow inbound connections to port `8787` on the computer's private network if Windows Firewall asks. Cleartext HTTP is enabled only in Android debug builds for local development. Configure a deployed HTTPS API before making a release build that needs to connect to the server. For iOS, build on macOS with Xcode and pass the HTTPS API URL with `--dart-define=API_BASE_URL=https://your-api-host`.

To build an installable Android package:

```powershell
flutter build apk --release
```

The APK is written to `build\app\outputs\flutter-apk\app-release.apk`. iOS builds require macOS and Xcode; this repository now includes the iOS project scaffold as well.

## Deploy the API with Supabase

The API uses `api/data.json` for local development. When both `SUPABASE_URL` and `SUPABASE_SECRET_KEY` are set, it stores the same BarberBook state in Supabase Postgres through the REST API. The older `SUPABASE_SERVICE_ROLE_KEY` is also supported. Keep either server key on the server only; never put it in Flutter or commit it to Git.

1. Create a Supabase project and run [`api/supabase-schema.sql`](api/supabase-schema.sql) in the Supabase SQL Editor.
2. For an existing local database, migrate it once before connecting the deployed API. In PowerShell, from the repository root:

   ```powershell
   $env:SUPABASE_URL = 'https://<project-ref>.supabase.co'
   $env:SUPABASE_SECRET_KEY = '<server-side secret key>'
   node api/migrate-to-supabase.mjs
   ```

   The migration stops if the cloud state row already exists. It copies the local users, barber profiles, bookings, reviews, and password hashes. Treat the key and migrated data as private.

3. In the Render API Web Service, keep **Root Directory** blank, use `node api/server.mjs` as the start command, and set `SUPABASE_URL` and `SUPABASE_SECRET_KEY` as environment variables. Remove `BARBERBOOK_DB`; no Render disk is needed.
4. Build the web app using the deployed API URL, then deploy `build/web` to static hosting:

   ```powershell
   flutter build web --release --dart-define=API_BASE_URL=https://<your-render-service>.onrender.com
   ```

Supabase Free projects can pause after a period of low activity, and Render Free web services sleep after 15 minutes without requests. This is suitable for a demo, not a production availability guarantee. Local JSON storage remains in place when Supabase environment variables are absent.

## Account and approval flow

- Customers create an account and sign in to browse approved shops, book services, and manage appointments.
- A barber can register a name, shop, email, phone, and password. Their application remains pending until an admin approves it.
- Admins can approve or reject applications, or create an approved barber account and choose its initial password.
- Barber accounts can manage services and availability, and accept, decline, or complete appointments.

Passwords are hashed by the API. Sessions are held in memory and expire after 12 hours. The app does not yet connect SMS OTP or a payment gateway.

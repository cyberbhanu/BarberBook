# BarberBook

Flutter booking app with a local Node API for accounts, barber approval, services, and appointments.

## Run on this computer

Open two PowerShell terminals in the project folder.

Terminal 1 starts the API. Set an admin password before the first launch, or let the API generate a one-time password and print it to the terminal:

```powershell
$env:ADMIN_PASSWORD = 'choose-a-private-password'
node api/server.mjs
```

The initial admin email is `admin@barberbook.local`. The API saves account and booking data to `api/data.json` and listens only on this computer at `http://127.0.0.1:8787`. You can change the admin password from the app after signing in.

Terminal 2 starts Flutter Web:

```powershell
flutter pub get
flutter run -d chrome
```

## Account and approval flow

- Customers create an account and sign in to browse approved shops, book services, and manage appointments.
- A barber can register a name, shop, email, phone, and password. Their application remains pending until an admin approves it.
- Admins can approve or reject applications, or create an approved barber account and choose its initial password.
- Barber accounts can manage services and availability, and accept, decline, or complete appointments.

Passwords are hashed on the local API. Sessions are held in memory and expire after 12 hours. This setup is for local development on one computer; it is not deployed for remote or multi-device use. It does not yet connect SMS OTP, a payment gateway, or production hosting. Use TLS, a managed database, secure secret storage, and a deployed API before using real customer data.

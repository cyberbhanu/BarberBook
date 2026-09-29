import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'booking_export.dart';

void main() => runApp(const BarberBookApp());

const ink = Color(0xFF101B20);
const gold = Color(0xFFE6AD43);
const paper = Color(0xFFF7F5F0);
const muted = Color(0xFF7B8588);
const timeSlots = ['09:00 AM', '10:00 AM', '11:30 AM', '01:00 PM', '03:30 PM', '05:00 PM'];

String weekdayName(DateTime date) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][date.weekday - 1];
DateTime slotDate(DateTime date, String label) {
  final pieces = label.split(' ');
  final hm = pieces.first.split(':');
  var hour = int.parse(hm[0]) % 12;
  if (pieces.last == 'PM') hour += 12;
  return DateTime(date.year, date.month, date.day, hour, int.parse(hm[1]));
}

class BarberBookApp extends StatelessWidget {
  const BarberBookApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BarberBook',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: paper,
          colorScheme: ColorScheme.fromSeed(seedColor: gold, primary: ink,
              surface: Colors.white, secondary: gold),
          fontFamily: 'Roboto',
          appBarTheme: const AppBarTheme(backgroundColor: paper, foregroundColor: ink,
            elevation: 0, centerTitle: false),
        ),
        home: const BookingShell(),
      );
}

class Barber {
  const Barber(this.name, this.shop, this.rating, this.distance, this.price,
      this.initials, this.color, this.specialty, [this.id = '']);
  final String name, shop, rating, distance, price, initials, specialty, id;
  final Color color;
}

const barbers = [
  Barber('Rahul Kumar', 'Royal Cuts', '4.8', '1.2 km', '₹150', 'RK', Color(0xFF34504C), 'Classic cuts'),
  Barber('Amit Verma', 'Gentleman’s Hub', '4.7', '2.1 km', '₹120', 'AV', Color(0xFF705142), 'Beard & fade'),
  Barber('Arjun Singh', 'Style Studio', '4.9', '2.8 km', '₹180', 'AS', Color(0xFF665B40), 'Modern styles'),
];

class BookingShell extends StatefulWidget {
  const BookingShell({super.key});
  @override
  State<BookingShell> createState() => _BookingShellState();
}

class _BookingShellState extends State<BookingShell> {
  final api = BarberBookApi();
  Timer? _adminRefreshTimer;
  bool _refreshing = false;
  bool signedIn = false;
  bool creatingAccount = false;
  bool acceptedTerms = false;
  int authRole = 0;
  int tab = 0;
  int bookingTab = 0;
  int adminBookingRange = 0; // 0 all, 1 daily, 2 monthly
  DateTime adminBookingDate = DateTime.now();
  int mode = 0; // 0: customer, 1: barber, 2: admin
  bool requestAccepted = false;
  bool locationLoading = false;
  String currentLocationLabel = 'Tap to use your location';
  Barber? selectedBarber;
  String? selectedServiceFilter;
  String selectedService = 'Haircut';
  String selectedTime = '10:00 AM';
  final FocusNode searchFocusNode = FocusNode();
  DateTime selectedDate = DateTime.now();
  bool booked = false;
  final search = TextEditingController();
  final authFormKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final shopController = TextEditingController();
  final services = const {'Haircut': 150, 'Beard trim': 100, 'Haircut + Beard': 220, 'Facial': 300};
  Map<String, dynamic>? currentUser;
  Map<String, dynamic>? currentBarber;
  List<dynamic> remoteBarbers = [];
  List<dynamic> remoteBookings = [];
  List<dynamic> managedBarbers = [];
  List<dynamic> barberServicesRemote = [];
  List<dynamic> customerReviews = [];
  Set<String> favoriteBarberIds = {};
  Map<String, dynamic> adminStats = {};
  @override
  void initState() {
    super.initState();
    // Poll the API while an admin is signed in so bookings from customers
    // and barbers show up without requiring a manual reload.
    _adminRefreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && signedIn && mode == 2) refreshData(silent: true);
    });
  }

  @override
  void dispose() {
    _adminRefreshTimer?.cancel();
    searchFocusNode.dispose();
    search.dispose();
    emailController.dispose();
    passwordController.dispose();
    nameController.dispose();
    phoneController.dispose();
    shopController.dispose();
    super.dispose();
  }
  List<Map<String, dynamic>> get availableServices {
    if (selectedBarber == null) return [];
    final profiles = remoteBarbers.whereType<Map>().where((b) => b['id'] == selectedBarber!.id).toList();
    if (profiles.isEmpty) return [];
    return (profiles.first['services'] as List<dynamic>? ?? []).whereType<Map>().map((s) => Map<String, dynamic>.from(s)).where((s) => s['enabled'] == true).toList();
  }
  int get total {
    for (final item in availableServices) { if (item['name'] == selectedService) return (item['price'] as num?)?.toInt() ?? 0; }
    return 0;
  }
  bool barberOpenOn(DateTime date) {
    if (selectedBarber == null) return false;
    final profile = remoteBarbers.whereType<Map>().where((b) => b['id'] == selectedBarber!.id).toList();
    if (profile.isEmpty) return false;
    final availability = profile.first['availability'] as Map?;
    return availability?[weekdayName(date)] == true;
  }
  List<String> get futureSlots {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    return timeSlots.where((slot) => selectedDay.isAfter(today) || slotDate(selectedDate, slot).isAfter(now)).toList();
  }

  void startBooking(Barber barber) {
    final profile = remoteBarbers.whereType<Map>().where((b) => b['id'] == barber.id).toList();
    final availability = profile.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(profile.first['availability'] as Map? ?? {});
    final shopServices = profile.isEmpty ? <dynamic>[] : (profile.first['services'] as List<dynamic>? ?? []).whereType<Map>().where((s) => s['enabled'] == true).toList();
    var date = DateTime.now();
    if (date.hour >= 17) date = DateTime(date.year, date.month, date.day + 1);
    for (var i = 0; i < 8 && availability[weekdayName(date)] != true; i++) { date = DateTime(date.year, date.month, date.day + 1); }
    var firstTime = timeSlots.first;
    if (date.year == DateTime.now().year && date.month == DateTime.now().month && date.day == DateTime.now().day) {
      firstTime = timeSlots.firstWhere((slot) => slotDate(date, slot).isAfter(DateTime.now()), orElse: () => timeSlots.first);
    }
    setState(() { selectedBarber = barber; selectedService = shopServices.isEmpty ? '' : (shopServices.first['name'] as String? ?? ''); selectedDate = date; selectedTime = firstTime; booked = false; });
  }

  Future<void> submitAuth() async {
    if (!(authFormKey.currentState?.validate() ?? false)) return;
    if (creatingAccount && !acceptedTerms) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please accept the Terms & Conditions.')));
      return;
    }
    try {
      if (creatingAccount) {
        if (authRole == 2) throw Exception('Admin accounts are created by the system administrator.');
        final result = await api.register(
          name: nameController.text.trim(), email: emailController.text.trim(), password: passwordController.text,
          role: authRole == 1 ? 'barber' : 'customer', phone: phoneController.text.trim(),
          shop: authRole == 1 ? shopController.text.trim() : null,
        );
        if (authRole == 1) {
          setState(() => creatingAccount = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result['message'] as String? ?? 'Application sent for admin approval.')));
          return;
        }
      }
      final result = await api.login(emailController.text.trim(), passwordController.text);
      final user = Map<String, dynamic>.from(result['user'] as Map);
      final role = user['role'] as String?;
      setState(() {
        currentUser = user;
        mode = role == 'admin' ? 2 : role == 'barber' ? 1 : 0;
        signedIn = true;
        creatingAccount = false;
        tab = 0;
      });
      await refreshData();
      if (mode == 0) refreshCurrentLocation();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> refreshData({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      if (mode == 2) {
        final results = await Future.wait([api.get('/admin/barbers'), api.get('/bookings'), api.get('/admin/overview')]);
        if (!mounted) return;
        setState(() { managedBarbers = results[0]['barbers'] as List<dynamic>; remoteBookings = results[1]['bookings'] as List<dynamic>; adminStats = Map<String, dynamic>.from(results[2]); });
      } else if (mode == 1) {
        final results = await Future.wait([api.get('/me'), api.get('/bookings'), api.get('/barber/services')]);
        if (!mounted) return;
        setState(() { currentUser = Map<String, dynamic>.from(results[0]['user'] as Map); currentBarber = results[0]['barber'] == null ? null : Map<String, dynamic>.from(results[0]['barber'] as Map); remoteBookings = results[1]['bookings'] as List<dynamic>; barberServicesRemote = results[2]['services'] as List<dynamic>; });
      } else {
        final results = await Future.wait([api.get('/me'), api.get('/barbers'), api.get('/bookings'), api.get('/reviews')]);
        if (!mounted) return;
        final profile = Map<String, dynamic>.from(results[0]['user'] as Map);
        setState(() {
          currentUser = profile;
          favoriteBarberIds = (profile['favoriteBarberIds'] as List<dynamic>? ?? []).whereType<String>().toSet();
          remoteBarbers = results[1]['barbers'] as List<dynamic>;
          remoteBookings = results[2]['bookings'] as List<dynamic>;
          customerReviews = results[3]['reviews'] as List<dynamic>;
        });
      }
    } catch (error) {
      if (mounted && !silent) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    } finally {
      _refreshing = false;
    }
  }

  Future<void> signOut() async {
    try { await api.post('/auth/logout', {}); } catch (_) {}
    setState(() { api.token = null; currentUser = null; currentBarber = null; signedIn = false; mode = 0; tab = 0; remoteBookings = []; });
  }

  Future<void> refreshCurrentLocation() async {
    if (locationLoading || mode != 0) return;
    setState(() { locationLoading = true; currentLocationLabel = 'Finding your location…'; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Turn on location services, then tap to try again.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('Allow location access in your device or browser settings, then tap to try again.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
      );
      String label;
      if (kIsWeb) {
        final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
          'format': 'jsonv2', 'lat': position.latitude.toString(), 'lon': position.longitude.toString(),
          'zoom': '10', 'addressdetails': '1',
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) throw Exception('Could not look up the nearby area.');
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>? ?? {};
        label = (address['city'] ?? address['town'] ?? address['village'] ?? address['suburb'] ?? address['county'] ?? 'Current location').toString();
        final state = address['state']?.toString();
        if (state != null && state.isNotEmpty) label = '$label, $state';
      } else {
        final marks = await Geocoding().placemarkFromCoordinates(position.latitude, position.longitude);
        if (marks.isEmpty) {
          label = '${position.latitude.toStringAsFixed(3)}, ${position.longitude.toStringAsFixed(3)}';
        } else {
          final place = marks.first;
          final area = place.locality?.isNotEmpty == true ? place.locality : place.subAdministrativeArea;
          final region = place.administrativeArea;
          label = [area, region].whereType<String>().where((part) => part.isNotEmpty).toSet().join(', ');
          if (label.isEmpty) label = 'Current location';
        }
      }
      if (mounted) setState(() => currentLocationLabel = label);
    } catch (error) {
      if (mounted) setState(() => currentLocationLabel = 'Location unavailable · tap to retry');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => locationLoading = false);
    }
  }

  ImageProvider? imageDataProvider(Object? value) {
    if (value is! String || !value.startsWith('data:image/')) return null;
    final separator = value.indexOf(',');
    if (separator < 0) return null;
    try { return MemoryImage(base64Decode(value.substring(separator + 1))); } catch (_) { return null; }
  }

  ImageProvider? barberLogoProvider(String barberId) {
    for (final row in remoteBarbers.whereType<Map>()) {
      if (row['id'] == barberId) return imageDataProvider(row['logoData']);
    }
    if (currentBarber?['id'] == barberId) return imageDataProvider(currentBarber?['logoData']);
    return null;
  }

  Future<void> chooseProfileImage({required bool forBarber}) async {
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 900, maxHeight: 900, imageQuality: 75,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (bytes.length > 450000) {
        throw Exception('Choose an image under 450 KB. Try a smaller image.');
      }
      var mime = image.mimeType?.toLowerCase();
      mime ??= image.name.toLowerCase().endsWith('.png') ? 'image/png' : image.name.toLowerCase().endsWith('.webp') ? 'image/webp' : 'image/jpeg';
      if (!const {'image/jpeg', 'image/png', 'image/webp'}.contains(mime)) {
        throw Exception('Choose a JPEG, PNG, or WebP image.');
      }
      final key = forBarber ? 'logoData' : 'profileImageData';
      final result = await api.patch('/me', {key: 'data:$mime;base64,${base64Encode(bytes)}'});
      if (!mounted) return;
      final user = Map<String, dynamic>.from(result['user'] as Map);
      setState(() {
        currentUser = user;
        if (result['barber'] is Map) currentBarber = Map<String, dynamic>.from(result['barber'] as Map);
      });
      if (forBarber) await refreshData(silent: true);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(forBarber ? 'Shop logo updated.' : 'Profile photo updated.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  void handlePhoneBack() {
    if (selectedBarber != null) {
      setState(() => selectedBarber = null);
    } else if (tab != 0) {
      setState(() => tab = 0);
    }
  }

  Future<void> bookingAction(String id, String action) async {
    try { await api.post('/bookings/$id/$action', {}); await refreshData(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> reviewBarber(String id, String decision) async {
    try { await api.post('/admin/barbers/$id/$decision', {}); await refreshData(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> editManagedBarber(Map<String, dynamic> barber) async {
    final ownerName = TextEditingController(text: barber['ownerName'] as String? ?? '');
    final shop = TextEditingController(text: barber['shop'] as String? ?? '');
    final email = TextEditingController(text: barber['email'] as String? ?? '');
    final phone = TextEditingController(text: barber['phone'] as String? ?? '');
    final address = TextEditingController(text: barber['address'] as String? ?? '');
    final formKey = GlobalKey<FormState>();
    final changes = await showDialog<Map<String, String>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit barber details'),
        content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: ownerName, decoration: const InputDecoration(labelText: 'Barber name'), validator: (v) => v == null || v.trim().isEmpty ? 'Enter a name' : null),
            TextFormField(controller: shop, decoration: const InputDecoration(labelText: 'Shop name'), validator: (v) => v == null || v.trim().isEmpty ? 'Enter a shop name' : null),
            TextFormField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Login email'), validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email' : null),
            TextFormField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number')),
            TextFormField(controller: address, decoration: const InputDecoration(labelText: 'Shop address')),
          ]),
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.pop(dialogContext, {'ownerName': ownerName.text.trim(), 'shop': shop.text.trim(), 'email': email.text.trim(), 'phone': phone.text.trim(), 'address': address.text.trim()});
            }
          }, child: const Text('Save changes')),
        ],
      ),
    );
    ownerName.dispose(); shop.dispose(); email.dispose(); phone.dispose(); address.dispose();
    if (changes == null) return;
    try {
      await api.patch('/admin/barbers/${barber['id']}', changes);
      await refreshData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Barber details updated.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  List<Map<String, dynamic>> get filteredAdminBookings {
    final rows = remoteBookings.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
    final day = '${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}-${adminBookingDate.day.toString().padLeft(2, '0')}';
    final month = '${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}';
    final filtered = rows.where((booking) {
      final date = booking['date'] as String? ?? '';
      if (adminBookingRange == 1) return date == day;
      if (adminBookingRange == 2) return date.startsWith(month);
      return true;
    }).toList();
    filtered.sort((a, b) => '${b['date']} ${b['time']}'.compareTo('${a['date']} ${a['time']}'));
    return filtered;
  }

  Future<void> chooseAdminBookingDate() async {
    final date = await showDatePicker(context: context, initialDate: adminBookingDate, firstDate: DateTime(2020), lastDate: DateTime(2100), helpText: adminBookingRange == 2 ? 'Choose a date in the month' : 'Choose booking date');
    if (date != null) setState(() => adminBookingDate = date);
  }

  String _csvCell(Object? value) => '"${(value?.toString() ?? '').replaceAll('"', '""')}"';

  Future<void> exportAdminBookings() async {
    final rows = filteredAdminBookings;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('There are no bookings in this date range to export.')));
      return;
    }
    final csv = StringBuffer('Booking ID,Reference,Date,Time,Status,Customer,Customer Email,Customer Phone,Barber,Shop,Barber Phone,Service,Duration (minutes),Amount\r\n');
    for (final booking in rows) {
      final customer = booking['customer'] is Map ? Map<String, dynamic>.from(booking['customer'] as Map) : <String, dynamic>{};
      final barber = booking['barber'] is Map ? Map<String, dynamic>.from(booking['barber'] as Map) : <String, dynamic>{};
      final values = [booking['id'], booking['reference'], booking['date'], booking['time'], booking['status'], customer['name'], customer['email'], customer['phone'], barber['ownerName'], barber['shop'], barber['phone'], booking['service'], booking['duration'], booking['total']];
      csv.writeln(values.map(_csvCell).join(','));
    }
    final suffix = adminBookingRange == 1
        ? '${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}-${adminBookingDate.day.toString().padLeft(2, '0')}'
        : adminBookingRange == 2
            ? '${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}'
            : 'all';
    try {
      final downloaded = await downloadBookingCsv(csv.toString(), 'barberbook-bookings-$suffix.csv');
      if (!downloaded) await Clipboard.setData(ClipboardData(text: csv.toString()));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(downloaded ? 'Booking CSV downloaded (${rows.length} bookings).' : 'Booking CSV copied to clipboard (${rows.length} bookings).')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export bookings: $error')));
    }
  }

  Future<void> createBarberAccount() async {
    final name = TextEditingController(), shop = TextEditingController(), email = TextEditingController(), phone = TextEditingController(), password = TextEditingController(), address = TextEditingController();
    final form = GlobalKey<FormState>();
    final data = await showDialog<Map<String, String>?>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Create barber account'),
      content: SizedBox(width: 420, child: SingleChildScrollView(child: Form(key: form, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Barber full name'), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
        TextFormField(controller: shop, decoration: const InputDecoration(labelText: 'Shop name'), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
        TextFormField(controller: email, decoration: const InputDecoration(labelText: 'Login email'), keyboardType: TextInputType.emailAddress, validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email' : null),
        TextFormField(controller: phone, decoration: const InputDecoration(labelText: 'Phone number'), keyboardType: TextInputType.phone),
        TextFormField(controller: address, decoration: const InputDecoration(labelText: 'Shop address')),
        TextFormField(controller: password, decoration: const InputDecoration(labelText: 'Temporary password (8+ characters)'), obscureText: true, validator: (v) => v == null || v.length < 8 ? 'Use at least 8 characters' : null),
      ])))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')), FilledButton(onPressed: () { if (form.currentState?.validate() ?? false) Navigator.pop(dialogContext, {'name': name.text.trim(), 'shop': shop.text.trim(), 'email': email.text.trim(), 'phone': phone.text.trim(), 'address': address.text.trim(), 'password': password.text}); }, child: const Text('Create account'))],
    ));
    if (data == null) return;
    try {
      await api.post('/admin/barbers', data);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Barber account created for ${data['email']}. Share the temporary password securely.')));
      await refreshData();
    } catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> addBarberService() async {
    final name = TextEditingController(), price = TextEditingController(), duration = TextEditingController(text: '30');
    final data = await showDialog<Map<String, dynamic>?>(context: context, builder: (ctx) => AlertDialog(title: const Text('Add service'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'Service name')), TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (₹)')), TextField(controller: duration, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () { final value = int.tryParse(price.text); if (name.text.trim().isEmpty || value == null || value <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a service name and valid price.'))); return; } Navigator.pop(ctx, {'name': name.text.trim(), 'price': value, 'duration': int.tryParse(duration.text) ?? 30}); }, child: const Text('Save'))]));
    if (data == null) return;
    try { await api.post('/barber/services', data); await refreshData(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> editBarberService(Map service) async {
    final price = TextEditingController(text: '${service['price']}');
    final enabled = await showDialog<bool?>(context: context, builder: (ctx) => AlertDialog(title: Text('Update ${service['name']}'), content: TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (₹)')), actions: [TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Disable')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))]));
    if (enabled == null) return;
    final value = int.tryParse(price.text);
    if (enabled && (value == null || value < 0)) return;
    try { await api.request('/barber/services/${service['id']}', method: 'PATCH', data: {'enabled': enabled, if (enabled) 'price': value}, authenticated: true); await refreshData(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> setAvailability(String day, bool enabled) async {
    try { await api.request('/barber/availability', method: 'PATCH', data: {'day': day, 'enabled': enabled}, authenticated: true); await refreshData(); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> changePasswordDialog() async {
    final current = TextEditingController(), next = TextEditingController();
    final result = await showDialog<Map<String, String>?>(context: context, builder: (ctx) => AlertDialog(title: const Text('Change password'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')), TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New password (8+ characters)'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () { if (current.text.isEmpty || next.text.length < 8) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter your current password and a new password of at least 8 characters.'))); return; } Navigator.pop(ctx, {'currentPassword': current.text, 'newPassword': next.text}); }, child: const Text('Update'))]));
    if (result == null) return;
    try { await api.post('/auth/change-password', result); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated.'))); }
    catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', '')))); }
  }

  Future<void> editProfileDialog() async {
    final name = TextEditingController(text: currentUser?['name'] as String? ?? '');
    final phone = TextEditingController(text: currentUser?['phone'] as String? ?? '');
    final form = GlobalKey<FormState>();
    final data = await showDialog<Map<String, String>?>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Edit profile'),
      content: Form(key: form, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Full name'), validator: (value) => value == null || value.trim().isEmpty ? 'Enter your name' : null),
        TextFormField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number')),
        TextFormField(initialValue: currentUser?['email'] as String? ?? '', enabled: false, decoration: const InputDecoration(labelText: 'Email')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        FilledButton(onPressed: () { if (form.currentState?.validate() ?? false) Navigator.pop(dialogContext, {'name': name.text.trim(), 'phone': phone.text.trim()}); }, child: const Text('Save'))],
    ));
    if (data == null) return;
    try {
      final result = await api.patch('/me', data);
      if (!mounted) return;
      setState(() => currentUser = Map<String, dynamic>.from(result['user'] as Map));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> toggleFavorite(Barber barber) async {
    final next = Set<String>.from(favoriteBarberIds);
    if (!next.add(barber.id)) next.remove(barber.id);
    try {
      final result = await api.patch('/me', {'favoriteBarberIds': next.toList()});
      if (!mounted) return;
      final profile = Map<String, dynamic>.from(result['user'] as Map);
      setState(() {
        currentUser = profile;
        favoriteBarberIds = (profile['favoriteBarberIds'] as List<dynamic>? ?? []).whereType<String>().toSet();
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> showInfo(String title, String message) => showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
    title: Text(title), content: Text(message), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done'))],
  ));

  Future<void> openProfileAction(String title) async {
    switch (title) {
      case 'My bookings':
        setState(() => tab = 1);
        break;
      case 'Favourites':
        await showFavourites();
        break;
      case 'Payment methods':
        await showInfo('Payment methods', 'Online payments are not connected yet. Pay your barber at the shop after your appointment.');
        break;
      case 'Reviews':
        await showReviews();
        break;
      case 'Notifications':
        await showNotifications();
        break;
      case 'Help & support':
        await showInfo('Help & support', 'To book, choose a barber and service, select an open date and time, then confirm. Your appointment will appear under My bookings. For account access, contact your BarberBook administrator.');
        break;
      case 'Terms & privacy':
        await showInfo('Terms & privacy', 'BarberBook stores your account and appointment details on its configured service. Share only accurate contact information. Cancellations and shop availability are handled by the barber.');
        break;
    }
  }

  Future<void> showFavourites() async {
    await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Favourite barbers'),
      content: SizedBox(width: 420, child: favoriteBarberIds.isEmpty
          ? const Text('You have not saved a barber yet. Use the heart on a barber card to add one.')
          : ListView(shrinkWrap: true, children: remoteBarbers.whereType<Map>().where((row) => favoriteBarberIds.contains(row['id'])).map((row) {
              final barber = barberFromMap(Map<String, dynamic>.from(row));
              return ListTile(title: Text(barber.shop), subtitle: Text(barber.name), leading: const Icon(Icons.favorite, color: Color(0xFFB74B3B)),
                trailing: IconButton(tooltip: 'Book ${barber.shop}', icon: const Icon(Icons.calendar_month_outlined), onPressed: () { Navigator.pop(dialogContext); setState(() => tab = 0); startBooking(barber); }));
            }).toList())),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
    ));
  }

  Future<void> showNotifications() async {
    final notices = remoteBookings.whereType<Map>().toList();
    await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Notifications'),
      content: SizedBox(width: 420, child: notices.isEmpty
          ? const Text('No appointment notifications yet. New booking updates will appear here.')
          : ListView(shrinkWrap: true, children: notices.map((row) {
              final booking = Map<String, dynamic>.from(row);
              final barber = booking['barber'] is Map ? Map<String, dynamic>.from(booking['barber'] as Map) : <String, dynamic>{};
              final status = (booking['status'] as String? ?? 'pending').toUpperCase();
              return ListTile(leading: const Icon(Icons.notifications_active_outlined, color: Color(0xFFAD7A29)),
                title: Text('Appointment $status'), subtitle: Text('${barber['shop'] ?? 'Barber shop'} · ${booking['date']} at ${booking['time']}'));
            }).toList())),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done'))],
    ));
  }

  Future<void> showReviews() async {
    final pending = remoteBookings.whereType<Map>().where((booking) => booking['status'] == 'completed' &&
      !customerReviews.whereType<Map>().any((review) => review['bookingId'] == booking['id'])).toList();
    await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('My reviews'),
      content: SizedBox(width: 420, child: ListView(shrinkWrap: true, children: [
        ...customerReviews.whereType<Map>().map((review) => ListTile(leading: const Icon(Icons.star, color: gold),
          title: Text('${review['rating']} stars'), subtitle: Text((review['comment'] as String?)?.isNotEmpty == true ? review['comment'] as String : 'Your appointment review'))),
        ...pending.map((booking) => ListTile(title: Text('Review ${booking['service']}'), subtitle: Text('${booking['date']} · ${booking['time']}'),
          trailing: TextButton(onPressed: () { Navigator.pop(dialogContext); writeReview(Map<String, dynamic>.from(booking)); }, child: const Text('Write')))),
        if (customerReviews.isEmpty && pending.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Reviews become available after a barber completes your appointment.')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
    ));
  }

  Future<void> writeReview(Map<String, dynamic> booking) async {
    var rating = 5;
    final comment = TextEditingController();
    final data = await showDialog<Map<String, dynamic>?>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, updateDialog) => AlertDialog(
      title: const Text('Rate your appointment'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(spacing: 2, children: List.generate(5, (index) => IconButton(tooltip: '${index + 1} stars', onPressed: () => updateDialog(() => rating = index + 1), icon: Icon(index < rating ? Icons.star : Icons.star_border, color: gold)))),
        TextField(controller: comment, maxLines: 3, maxLength: 1000, decoration: const InputDecoration(labelText: 'Review (optional)', border: OutlineInputBorder())),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, {'bookingId': booking['id'], 'rating': rating, 'comment': comment.text.trim()}), child: const Text('Submit review'))],
    )));
    if (data == null) return;
    try {
      await api.post('/reviews', data);
      await refreshData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks for your review.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Barber barberFromMap(Map<String, dynamic> value) {
    final list = (value['services'] as List<dynamic>? ?? []);
    final prices = list.whereType<Map>().map((s) => (s['price'] as num?)?.toInt() ?? 0).toList();
    final ownerName = value['ownerName'] as String? ?? 'Barber';
    final colors = [const Color(0xFF34504C), const Color(0xFF705142), const Color(0xFF665B40)];
    final color = colors[ownerName.hashCode.abs() % colors.length];
    return Barber(ownerName, value['shop'] as String? ?? 'Barber shop', '${value['rating'] ?? 5}', '', '₹${prices.isEmpty ? 0 : prices.reduce((a, b) => a < b ? a : b)}', ownerName.split(' ').map((p) => p.isEmpty ? '' : p[0]).take(2).join().toUpperCase(), color, 'Barber', value['id'] as String? ?? '');
  }

  Future<void> finishBooking() async {
    if (selectedBarber == null) return;
    try {
      final barberRows = remoteBarbers.whereType<Map>().where((b) => b['id'] == selectedBarber!.id).toList();
      final servicesForBarber = barberRows.isEmpty ? <dynamic>[] : (barberRows.first['services'] as List<dynamic>? ?? []);
      String? serviceId;
      for (final item in servicesForBarber.whereType<Map>()) {
        if (item['name'] == selectedService) { serviceId = item['id'] as String?; break; }
      }
      await api.post('/bookings', {'barberId': selectedBarber!.id, 'serviceId': serviceId,
        'date': '${selectedDate.year.toString().padLeft(4, '0')}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}', 'time': selectedTime});
      setState(() { booked = true; selectedBarber = null; tab = 1; });
      await refreshData();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!signedIn) return authPage();
    final pages = mode == 0
        ? [homePage(), bookingsPage(), profilePage()]
        : mode == 1
            ? [barberDashboard(), barberAppointments(), barberServices()]
            : [adminDashboard(), adminBarbers(), adminBookings()];
    final destinations = mode == 0
        ? const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'Bookings'),
            NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Profile'),
          ]
        : mode == 1
            ? const [
                NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Overview'),
                NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Appointments'),
                NavigationDestination(icon: Icon(Icons.content_cut_outlined), selectedIcon: Icon(Icons.content_cut), label: 'Services'),
              ]
            : const [
                NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Overview'),
                NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'Barbers'),
                NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Bookings'),
              ];
    return PopScope(
      canPop: selectedBarber == null && tab == 0,
      onPopInvokedWithResult: (didPop, result) { if (!didPop) handlePhoneBack(); },
      child: Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false,
        leading: selectedBarber != null || tab != 0 ? IconButton(tooltip: 'Back', onPressed: handlePhoneBack, icon: const Icon(Icons.arrow_back_rounded)) : null,
        title: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(11)),
          child: const Icon(Icons.content_cut_rounded, color: gold, size: 19)),
        const SizedBox(width: 10), Text(mode == 0 ? 'BarberBook' : mode == 1 ? 'Barber Portal' : 'Admin Panel', style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.4)),
      ]), actions: [IconButton(tooltip: 'Change password', onPressed: changePasswordDialog, icon: const Icon(Icons.key_rounded)), IconButton(tooltip: 'Log out', onPressed: signOut, icon: const Icon(Icons.logout_rounded)), const SizedBox(width: 5)]),
      body: SafeArea(
        child: Center(
          // Keep touch targets comfortable on phones and prevent stretched
          // cards/forms on tablets and desktop-sized windows.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: SizedBox(width: double.infinity, child: pages[tab]),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(height: 70, selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i),
        backgroundColor: Colors.white, indicatorColor: gold.withValues(alpha: .18),
        destinations: destinations),
    ));
  }

  Widget authPage() => Scaffold(backgroundColor: paper, body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Center(child: Container(width: 62, height: 62, decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(20)), child: const Icon(Icons.content_cut_rounded, color: gold, size: 30))),
    const SizedBox(height: 15), const Center(child: Text('BARBERBOOK', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.1))),
    const SizedBox(height: 5), Center(child: Text(creatingAccount ? 'Create your account to get started' : 'Your next great look is one booking away', style: TextStyle(color: muted, fontSize: 12))),
    const SizedBox(height: 25),
    const Text('Continue as', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)), const SizedBox(height: 10),
    Row(children: [authRoleCard(0, Icons.person_outline_rounded, 'Customer'), const SizedBox(width: 8), authRoleCard(1, Icons.storefront_outlined, 'Barber'), const SizedBox(width: 8), authRoleCard(2, Icons.admin_panel_settings_outlined, 'Admin')]),
    const SizedBox(height: 18),
    Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Form(key: authFormKey, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(creatingAccount ? 'Create account' : 'Welcome back', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)), const SizedBox(height: 5), Text(creatingAccount ? 'Join BarberBook today.' : 'Log in to continue.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 17),
      if (creatingAccount) ...[
        authInput(nameController, 'Full name', Icons.person_outline, validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null), const SizedBox(height: 11),
        authInput(phoneController, 'Mobile number', Icons.phone_outlined, keyboard: TextInputType.phone, validator: (v) => (v == null || v.trim().length < 10) ? 'Enter a valid mobile number' : null), const SizedBox(height: 11),
      ],
        if (authRole == 1 && creatingAccount) ...[
          authInput(shopController, 'Shop name', Icons.storefront_outlined, validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your shop name' : null), const SizedBox(height: 11),
        ],
        authInput(emailController, 'Email', Icons.mail_outline_rounded, keyboard: TextInputType.emailAddress, validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email address' : null), const SizedBox(height: 11),
        authInput(passwordController, 'Password (at least 8 characters)', Icons.lock_outline_rounded, obscure: true, validator: (v) => (v == null || v.length < 8) ? 'Use at least 8 characters' : null),
      if (creatingAccount) ...[const SizedBox(height: 8), CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, value: acceptedTerms, onChanged: (v) => setState(() => acceptedTerms = v ?? false), controlAffinity: ListTileControlAffinity.leading, title: const Text('I agree to the Terms & Conditions', style: TextStyle(fontSize: 11)))],
      if (!creatingAccount) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => showInfo('Password help', 'Password reset by email is not configured. If you are signed in on another device, use Change password. Otherwise ask your BarberBook administrator for help.'), child: const Text('Forgot password?', style: TextStyle(color: Color(0xFFAD7720), fontSize: 11)))),
      const SizedBox(height: 4), SizedBox(width: double.infinity, height: 48, child: FilledButton(onPressed: () {
        submitAuth();
      }, style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: ink, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)), textStyle: const TextStyle(fontWeight: FontWeight.w800)), child: Text(creatingAccount ? 'CREATE ACCOUNT' : 'LOG IN'))),
      const SizedBox(height: 7), Center(child: TextButton(onPressed: () { if (!creatingAccount || authRole != 2) setState(() => creatingAccount = !creatingAccount); }, child: Text(creatingAccount ? 'Already have an account? Log in' : authRole == 2 ? 'Admin accounts are created by the system' : 'Don’t have an account? Create one', style: const TextStyle(fontSize: 11, color: ink)))),
    ]))),
  ]))))));

  Widget authRoleCard(int role, IconData icon, String label) => Expanded(child: InkWell(onTap: () => setState(() => authRole = role), borderRadius: BorderRadius.circular(13), child: Container(padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4), decoration: BoxDecoration(color: authRole == role ? ink : Colors.white, borderRadius: BorderRadius.circular(13), border: Border.all(color: authRole == role ? ink : const Color(0xFFE8E4DC))), child: Column(children: [Icon(icon, size: 20, color: authRole == role ? gold : muted), const SizedBox(height: 5), Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: authRole == role ? Colors.white : ink))]))));

  Widget authInput(TextEditingController controller, String label, IconData icon, {bool obscure = false, TextInputType? keyboard, String? Function(String?)? validator}) => TextFormField(controller: controller, obscureText: obscure, keyboardType: keyboard, validator: validator, decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 18), filled: true, fillColor: paper, contentPadding: const EdgeInsets.symmetric(vertical: 13), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), errorStyle: const TextStyle(fontSize: 10)));

  Widget homePage() => selectedBarber != null ? bookingFlow() : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Good morning, ${currentUser?['name'] ?? 'there'} 👋', style: TextStyle(color: muted, fontSize: 13)),
      const SizedBox(height: 4), InkWell(onTap: refreshCurrentLocation, borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [if (locationLoading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: gold)) else const Icon(Icons.location_on_outlined, size: 16, color: gold), const SizedBox(width: 3), Flexible(child: Text(currentLocationLabel, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)), const SizedBox(width: 3), const Icon(Icons.refresh_rounded, size: 14, color: muted)]))),
    ])), CircleAvatar(backgroundColor: const Color(0xFFF1E6D0), child: const Text('P', style: TextStyle(color: ink, fontWeight: FontWeight.bold)))]),
    const SizedBox(height: 22),
    InkWell(onTap: () => FocusScope.of(context).requestFocus(searchFocusNode), borderRadius: BorderRadius.circular(22), child: Container(height: 176, width: double.infinity, padding: const EdgeInsets.all(20), decoration: BoxDecoration(
      color: ink, borderRadius: BorderRadius.circular(22),
      gradient: const LinearGradient(colors: [Color(0xFF101B20), Color(0xFF24403A)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
      child: Stack(children: [
        Positioned(right: -4, bottom: -20, child: Icon(Icons.content_cut_rounded, size: 142, color: Colors.white.withValues(alpha: .055))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: gold.withValues(alpha: .2), borderRadius: BorderRadius.circular(20)), child: const Text('YOUR NEXT GREAT LOOK', style: TextStyle(color: gold, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2))),
          const Spacer(), const Text('A fresh cut,\njust around the corner.', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 10), Row(children: [const Text('Find your barber', style: TextStyle(color: Colors.white70, fontSize: 12)), const SizedBox(width: 5), Icon(Icons.arrow_forward_rounded, color: gold, size: 16)])
        ])
      ]))),
    const SizedBox(height: 22),
    TextField(focusNode: searchFocusNode, controller: search, onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: 'Search barbers, services…', prefixIcon: const Icon(Icons.search_rounded), filled: true, fillColor: Colors.white, contentPadding: EdgeInsets.zero, border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none))),
    const SizedBox(height: 23), sectionTitle('Explore services', 'See all', onActionTap: () => setState(() => selectedServiceFilter = null)), const SizedBox(height: 12),
    SizedBox(height: 88, child: ListView(scrollDirection: Axis.horizontal, children: [
      serviceChip('Haircut', Icons.person_outline_rounded), serviceChip('Beard', Icons.face_retouching_natural), serviceChip('Hair styling', Icons.auto_awesome_outlined), serviceChip('Facial', Icons.spa_outlined),
    ])),
    const SizedBox(height: 18), sectionTitle('Nearby barbers', 'View all', onActionTap: () => setState(() { selectedServiceFilter = null; search.clear(); })), const SizedBox(height: 12),
    if (remoteBarbers.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 25), child: Center(child: Column(children: [Text('No approved barbers nearby yet. Check back soon.', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 8), TextButton.icon(onPressed: refreshData, icon: const Icon(Icons.refresh), label: const Text('Refresh barbers'))])))
    else ...remoteBarbers.whereType<Map>().where((b) {
      final services = (b['services'] as List<dynamic>? ?? []).whereType<Map>();
      final query = '${b['ownerName']} ${b['shop']} ${services.map((item) => item['name']).join(' ')}'.toLowerCase();
      final queryMatches = query.contains(search.text.toLowerCase());
      final filter = selectedServiceFilter?.toLowerCase();
      final serviceMatches = filter == null || services.any((service) {
        final name = (service['name'] as String? ?? '').toLowerCase();
        return service['enabled'] == true && (name.contains(filter) || (filter == 'hair styling' && name.contains('haircut')));
      });
      return queryMatches && serviceMatches;
    }).map((b) => barberCard(barberFromMap(Map<String, dynamic>.from(b)))),
  ]));

  Widget bookingFlow() => SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [IconButton(onPressed: () => setState(() => selectedBarber = null), icon: const Icon(Icons.arrow_back_rounded)), const Text('Book appointment', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20))]),
    const SizedBox(height: 8),
    Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(17)), child: Row(children: [CircleAvatar(radius: 25, backgroundColor: selectedBarber!.color, child: Text(selectedBarber!.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(selectedBarber!.shop, style: const TextStyle(fontWeight: FontWeight.w800)), Text('${selectedBarber!.name}  ·  ★ ${selectedBarber!.rating}', style: TextStyle(color: muted, fontSize: 12))])), const Icon(Icons.verified_rounded, color: Color(0xFF278454))])),
    const SizedBox(height: 22), const Text('Choose service', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    if (availableServices.isEmpty) Text('This shop has no services available right now.', style: TextStyle(color: muted, fontSize: 12)) else ...availableServices.map((e) => InkWell(onTap: () => setState(() => selectedService = e['name'] as String), child: Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: selectedService == e['name'] ? gold : Colors.transparent, width: 1.5)), child: Row(children: [Icon(selectedService == e['name'] ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selectedService == e['name'] ? const Color(0xFFAD7A29) : muted, size: 19), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), Text('${e['duration']} minutes', style: TextStyle(color: muted, fontSize: 10))])), Text('₹${e['price']}', style: const TextStyle(fontWeight: FontWeight.w800))])))),
    const SizedBox(height: 12), const Text('Choose date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    SizedBox(height: 70, child: ListView(scrollDirection: Axis.horizontal, children: List.generate(7, (i) {
      final today = DateTime.now();
      final date = DateTime(today.year, today.month, today.day + i);
      final active = selectedDate.year == date.year && selectedDate.month == date.month && selectedDate.day == date.day;
      final row = remoteBarbers.whereType<Map>().where((b) => b['id'] == selectedBarber!.id).toList();
      final availability = row.isEmpty ? null : row.first['availability'] as Map?;
      final open = availability?[weekdayName(date)] == true;
      return InkWell(onTap: open ? () => setState(() => selectedDate = date) : null, child: Container(width: 56, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: active ? ink : open ? Colors.white : const Color(0xFFEAE7E1), borderRadius: BorderRadius.circular(14)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][date.weekday - 1], style: TextStyle(color: active ? Colors.white70 : open ? muted : const Color(0xFFAAA49A), fontSize: 10)), const SizedBox(height: 5), Text('${date.day}', style: TextStyle(color: active ? gold : open ? ink : const Color(0xFFAAA49A), fontWeight: FontWeight.w800, fontSize: 16))])));
    }))),
    const SizedBox(height: 18), const Text('Available time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: futureSlots
          .map((time) => ChoiceChip(
                label: Text(time, style: TextStyle(fontSize: 11, color: selectedTime == time ? Colors.white : ink)),
                selected: selectedTime == time,
                selectedColor: ink,
                backgroundColor: Colors.white,
                onSelected: (_) => setState(() => selectedTime = time),
              ))
          .toList(),
    ),
    const SizedBox(height: 20), Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Column(children: [detailRow(Icons.content_cut_rounded, selectedService), detailRow(Icons.calendar_month_outlined, '${selectedDate.day} ${['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][selectedDate.month - 1]} ${selectedDate.year} · $selectedTime'), const Divider(), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total', style: TextStyle(fontWeight: FontWeight.w700)), Text('₹$total', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))])])),
    const SizedBox(height: 14), SizedBox(width: double.infinity, height: 50, child: FilledButton.icon(onPressed: finishBooking, icon: const Icon(Icons.check_circle_outline_rounded, size: 17), label: Text('Confirm booking · ₹$total'), style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: ink, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), textStyle: const TextStyle(fontWeight: FontWeight.w800)))),
    const SizedBox(height: 8), Center(child: Text('Appointment request is sent to the barber for confirmation.', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 10))),
  ]));

  Widget sectionTitle(String title, String action, {required VoidCallback onActionTap}) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -.2)), TextButton(onPressed: onActionTap, child: Text(action, style: const TextStyle(color: Color(0xFFAB7720), fontSize: 12, fontWeight: FontWeight.w700)))]);

  Widget serviceChip(String title, IconData icon) => InkWell(onTap: () => setState(() => selectedServiceFilter = selectedServiceFilter == title ? null : title), borderRadius: BorderRadius.circular(16), child: Container(width: 78, margin: const EdgeInsets.only(right: 10), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: selectedServiceFilter == title ? ink : Colors.white, borderRadius: BorderRadius.circular(16)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: selectedServiceFilter == title ? gold : const Color(0xFFAD7A29), size: 23), const SizedBox(height: 6), Text(title, maxLines: 1, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: selectedServiceFilter == title ? Colors.white : ink))])));

  Widget barberCard(Barber barber) => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: Row(children: [
    Container(width: 66, height: 72, decoration: BoxDecoration(color: barber.color, borderRadius: BorderRadius.circular(14)), clipBehavior: Clip.antiAlias, child: barberLogoProvider(barber.id) == null ? Center(child: Text(barber.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20))) : Image(image: barberLogoProvider(barber.id)!, fit: BoxFit.cover)),
    const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(barber.shop, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)), const SizedBox(height: 4), Text(barber.name, style: TextStyle(color: muted, fontSize: 11)), const SizedBox(height: 7), Row(children: [const Icon(Icons.star_rounded, color: gold, size: 14), Text(' ${barber.rating}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)), Text('  ·  ${barber.distance}  ·  ${barber.price}+', style: TextStyle(color: muted, fontSize: 10))])])),
    IconButton(tooltip: favoriteBarberIds.contains(barber.id) ? 'Remove from favourites' : 'Add to favourites', onPressed: () => toggleFavorite(barber), icon: Icon(favoriteBarberIds.contains(barber.id) ? Icons.favorite : Icons.favorite_border, color: const Color(0xFFB74B3B), size: 20)),
    const SizedBox(width: 2), FilledButton(onPressed: () => startBooking(barber), style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: ink, padding: const EdgeInsets.symmetric(horizontal: 13), minimumSize: const Size(0, 38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))), child: const Text('Book', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)))
  ]));

  Widget bookingsPage() => Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('My bookings', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800)), const SizedBox(height: 5), Text('Your appointments, all in one place.', style: TextStyle(color: muted, fontSize: 13)), const SizedBox(height: 20),
    Row(children: ['Upcoming', 'Completed', 'Cancelled'].asMap().entries.map((entry) => Expanded(child: InkWell(onTap: () => setState(() => bookingTab = entry.key), child: Container(margin: const EdgeInsets.only(right: 6), padding: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(color: bookingTab == entry.key ? ink : Colors.white, borderRadius: BorderRadius.circular(12)), child: Text(entry.value, textAlign: TextAlign.center, style: TextStyle(color: bookingTab == entry.key ? Colors.white : muted, fontWeight: FontWeight.w700, fontSize: 11)))))).toList()),
    const SizedBox(height: 16),
    Builder(builder: (context) {
      final items = remoteBookings.whereType<Map>().where((b) => bookingTab == 0 ? ['pending', 'confirmed'].contains(b['status']) : bookingTab == 1 ? b['status'] == 'completed' : ['cancelled', 'rejected'].contains(b['status'])).toList();
      if (items.isEmpty) return Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Container(width: 76, height: 76, decoration: BoxDecoration(color: gold.withValues(alpha: .16), shape: BoxShape.circle), child: const Icon(Icons.calendar_month_outlined, color: Color(0xFFAD7A29), size: 34)), const SizedBox(height: 14), Text(bookingTab == 0 ? 'No upcoming appointments' : 'No bookings here yet', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height: 6), Text('Your next great haircut is a few taps away.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 18), if (bookingTab == 0) FilledButton(onPressed: () => setState(() => tab = 0), style: FilledButton.styleFrom(backgroundColor: ink), child: const Text('Find a barber'))])));
      return Expanded(child: ListView(children: items.map((b) => bookingCard(Map<String, dynamic>.from(b))).toList()));
    }),
  ]));

  Widget bookingCard(Map<String, dynamic> booking) {
    final barberData = booking['barber'] is Map ? Map<String, dynamic>.from(booking['barber'] as Map) : <String, dynamic>{};
    final status = booking['status'] as String? ?? 'pending';
    final canCancel = mode == 0 && ['pending', 'confirmed'].contains(status);
    final canReview = mode == 0 && status == 'completed' && !customerReviews.whereType<Map>().any((review) => review['bookingId'] == booking['id']);
    final statusColor = status == 'confirmed' || status == 'completed' ? const Color(0xFF258246) : status == 'pending' ? const Color(0xFFAD7720) : const Color(0xFFB74B3B);
    return Container(margin: const EdgeInsets.only(bottom: 11), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [CircleAvatar(backgroundColor: const Color(0xFF34504C), child: Text((barberData['ownerName'] as String? ?? 'B').split(' ').map((s) => s.isEmpty ? '' : s[0]).take(2).join().toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(barberData['shop'] as String? ?? 'Barber shop', style: const TextStyle(fontWeight: FontWeight.w800)), if (mode != 1) Text(barberData['ownerName'] as String? ?? '', style: TextStyle(color: muted, fontSize: 12)), if (mode == 1) Text(booking['customer'] is Map ? (booking['customer']['name'] as String? ?? '') : '', style: TextStyle(color: muted, fontSize: 12))])), Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: statusColor.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)), child: Text(status.toUpperCase(), style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)))]),
      const Divider(height: 25), detailRow(Icons.calendar_month_outlined, '${booking['date']}  ·  ${booking['time']}'), detailRow(Icons.content_cut_rounded, '${booking['service']}  ·  ₹${booking['total']}'),
      if (mode == 2 && booking['customer'] is Map) ...[
        detailRow(Icons.person_outline_rounded, 'Customer: ${booking['customer']['name']}'),
        detailRow(Icons.alternate_email_rounded, '${booking['customer']['email'] ?? ''} · ${booking['customer']['phone'] ?? ''}'),
      ],
      if (canCancel) SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => bookingAction(booking['id'] as String, 'cancel'), child: const Text('Cancel appointment'))),
      if (canReview) SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => writeReview(booking), icon: const Icon(Icons.star_outline_rounded), label: const Text('Write a review'))),
      if (mode == 1 && status == 'pending') Row(children: [Expanded(child: OutlinedButton(onPressed: () => bookingAction(booking['id'] as String, 'reject'), child: const Text('Decline'))), const SizedBox(width: 8), Expanded(child: FilledButton(onPressed: () => bookingAction(booking['id'] as String, 'accept'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF258246)), child: const Text('Accept')))]),
      if (mode == 1 && status == 'confirmed') SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => bookingAction(booking['id'] as String, 'complete'), child: const Text('Mark completed')))
    ]));
  }
  Widget detailRow(IconData icon, String text) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [Icon(icon, size: 16, color: muted), const SizedBox(width: 8), Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))]));

  Widget profilePage() => ListView(padding: const EdgeInsets.all(20), children: [
    const Text('My profile', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800)), const SizedBox(height: 20),
    Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(20)), child: Row(children: [CircleAvatar(radius: 27, backgroundColor: const Color(0xFFF1E6D0), backgroundImage: imageDataProvider(currentUser?['profileImageData']), child: imageDataProvider(currentUser?['profileImageData']) == null ? Text((currentUser?['name'] as String? ?? 'U').substring(0, 1).toUpperCase(), style: const TextStyle(color: ink, fontSize: 22, fontWeight: FontWeight.bold)) : null), const SizedBox(width: 13), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(currentUser?['name'] as String? ?? 'Customer', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)), const SizedBox(height: 4), Text(currentUser?['email'] as String? ?? '', style: const TextStyle(color: Colors.white60, fontSize: 12))])), IconButton(tooltip: 'Add or change profile photo', onPressed: () => chooseProfileImage(forBarber: false), icon: const Icon(Icons.add_a_photo_outlined, color: gold)), IconButton(tooltip: 'Edit profile', onPressed: editProfileDialog, icon: const Icon(Icons.edit_outlined, color: gold))])),
    const SizedBox(height: 22), ...[
      (Icons.calendar_month_outlined, 'My bookings'), (Icons.favorite_border_rounded, 'Favourites'), (Icons.credit_card_outlined, 'Payment methods'), (Icons.star_outline_rounded, 'Reviews'), (Icons.notifications_none_rounded, 'Notifications'), (Icons.help_outline_rounded, 'Help & support'), (Icons.privacy_tip_outlined, 'Terms & privacy'),
    ].map((entry) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 4), leading: Icon(entry.$1, color: const Color(0xFF586366), size: 21), title: Text(entry.$2, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), trailing: const Icon(Icons.chevron_right_rounded, color: muted), onTap: () => openProfileAction(entry.$2))),
      const SizedBox(height: 10), Center(child: TextButton(onPressed: signOut, child: const Text('Log out', style: TextStyle(color: Color(0xFFB74B3B), fontWeight: FontWeight.bold))))
  ]);

  Widget barberDashboard() => ListView(padding: const EdgeInsets.all(20), children: [
    Row(children: [InkWell(onTap: () => chooseProfileImage(forBarber: true), borderRadius: BorderRadius.circular(32), child: CircleAvatar(radius: 27, backgroundColor: ink, backgroundImage: imageDataProvider(currentBarber?['logoData']), child: imageDataProvider(currentBarber?['logoData']) == null ? const Icon(Icons.add_a_photo_outlined, color: gold, size: 20) : null)), const SizedBox(width: 12), Expanded(child: Text('Good morning, ${currentUser?['name'] ?? 'Barber'} 👋', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)))]),
    const SizedBox(height: 4), Text('Here’s how your shop is doing today.', style: TextStyle(color: muted, fontSize: 12)),
    const SizedBox(height: 18),
    Row(children: [Expanded(child: metricCard('Bookings', '${remoteBookings.length}', Icons.calendar_today_outlined, const Color(0xFFE7F0FA))), const SizedBox(width: 10), Expanded(child: metricCard('Earnings', '₹${remoteBookings.whereType<Map>().where((b) => b['status'] == 'completed').fold<int>(0, (sum, b) => sum + ((b['total'] as num?)?.toInt() ?? 0))}', Icons.currency_rupee, const Color(0xFFE5F4E9)))]),
    const SizedBox(height: 22), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Today’s appointments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), TextButton(onPressed: () => setState(() => tab = 1), child: const Text('View all'))]),
    const SizedBox(height: 6), if (remoteBookings.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text('No appointments yet.', style: TextStyle(color: muted, fontSize: 12))) else ...remoteBookings.whereType<Map>().take(3).map((b) => bookingCard(Map<String, dynamic>.from(b))),
    const SizedBox(height: 12), Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(17)), child: const Row(children: [Icon(Icons.tips_and_updates_outlined, color: gold), SizedBox(width: 12), Expanded(child: Text('Keep your availability up to date so customers can book with confidence.', style: TextStyle(color: Colors.white, fontSize: 12, height: 1.4))) ])),
  ]);

  Widget barberAppointments() => ListView(padding: const EdgeInsets.all(20), children: [
    const Text('Appointments', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('Manage today’s booking requests.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 18),
    if (remoteBookings.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 40), child: Center(child: Text('No appointments have been booked yet.', style: TextStyle(color: muted, fontSize: 12)))) else ...remoteBookings.whereType<Map>().map((b) => bookingCard(Map<String, dynamic>.from(b))),
  ]);

  Widget barberServices() => ListView(padding: const EdgeInsets.all(20), children: [
    Container(margin: const EdgeInsets.only(bottom: 18), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Row(children: [CircleAvatar(radius: 25, backgroundColor: ink, backgroundImage: imageDataProvider(currentBarber?['logoData']), child: imageDataProvider(currentBarber?['logoData']) == null ? const Icon(Icons.storefront_outlined, color: gold) : null), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Shop logo', style: TextStyle(fontWeight: FontWeight.w800)), Text(currentBarber?['shop'] as String? ?? 'Your shop', style: TextStyle(color: muted, fontSize: 12))])), OutlinedButton.icon(onPressed: () => chooseProfileImage(forBarber: true), icon: const Icon(Icons.upload_outlined), label: const Text('Add logo'))])),
    const Text('My services', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('Set the services customers can book.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 18),
    if (barberServicesRemote.isEmpty) Text('No services yet.', style: TextStyle(color: muted, fontSize: 12)) else ...barberServicesRemote.whereType<Map>().where((s) => s['enabled'] == true).map((s) => Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: gold.withValues(alpha: .18), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.content_cut_rounded, color: Color(0xFFAD7A29))), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(s['name'] as String? ?? 'Service', style: const TextStyle(fontWeight: FontWeight.w800)), Text('${s['duration']} min', style: TextStyle(color: muted, fontSize: 11))])), Text('₹${s['price']}', style: const TextStyle(fontWeight: FontWeight.w800)), IconButton(onPressed: () => editBarberService(s), icon: const Icon(Icons.edit_outlined, size: 18, color: muted))]))),
    SizedBox(height: 48, child: OutlinedButton.icon(onPressed: addBarberService, icon: const Icon(Icons.add), label: const Text('Add service'))), const SizedBox(height: 20),
    const Text('Weekly availability', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    ...['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].map((day) { final isAvailable = (currentBarber?['availability'] as Map?)?[day] == true; return SwitchListTile(contentPadding: EdgeInsets.zero, value: isAvailable, onChanged: (value) => setAvailability(day, value), title: Text(day, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), subtitle: Text(isAvailable ? '09:00 AM – 08:00 PM' : 'Closed', style: TextStyle(color: muted, fontSize: 11)), activeTrackColor: const Color(0xFF258246)); }),
  ]);

  Widget adminDashboard() => ListView(padding: const EdgeInsets.all(20), children: [
    const Text('Admin overview', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('Live BarberBook platform activity.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 18),
    Row(children: [Expanded(child: metricCard('Customers', '${adminStats['customers'] ?? 0}', Icons.people_outline, const Color(0xFFE7F0FA))), const SizedBox(width: 10), Expanded(child: metricCard('Bookings', '${adminStats['bookings'] ?? 0}', Icons.event_available_outlined, const Color(0xFFE5F4E9)))]), const SizedBox(height: 10),
    Row(children: [Expanded(child: metricCard('Approved barbers', '${adminStats['barbers'] ?? 0}', Icons.storefront_outlined, const Color(0xFFFFF2D9))), const SizedBox(width: 10), Expanded(child: metricCard('Completed sales', '₹${adminStats['revenue'] ?? 0}', Icons.currency_rupee, const Color(0xFFF1E8F7)))]),
    const SizedBox(height: 22), const Text('Needs attention', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    portalRow(Icons.verified_user_outlined, 'Barber applications', '${adminStats['pendingApplications'] ?? 0} pending review', onTap: () => setState(() => tab = 1)),
    const SizedBox(height: 14), const Text('Recent bookings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    if (remoteBookings.isEmpty) Text('No bookings have been made.', style: TextStyle(color: muted, fontSize: 12)) else ...remoteBookings.whereType<Map>().take(3).map((b) => bookingCard(Map<String, dynamic>.from(b))),
  ]);

  Widget adminBarbers() => ListView(padding: const EdgeInsets.all(20), children: [
    const Text('Barber management', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('Create accounts or review shop applications.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 14),
    SizedBox(height: 46, child: FilledButton.icon(onPressed: createBarberAccount, style: FilledButton.styleFrom(backgroundColor: ink), icon: const Icon(Icons.person_add_alt_1), label: const Text('Create barber login'))), const SizedBox(height: 20),
    const Text('Applications & accounts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
    if (managedBarbers.isEmpty) Padding(padding: const EdgeInsets.all(14), child: Text('No shop applications or barber accounts yet.', style: TextStyle(color: muted, fontSize: 12)))
    else ...managedBarbers.whereType<Map>().map((raw) {
      final barber = Map<String, dynamic>.from(raw);
      final status = barber['status'] as String? ?? 'pending';
      final pending = status == 'pending';
      final color = status == 'approved' ? const Color(0xFF258246) : status == 'pending' ? const Color(0xFFAD7720) : const Color(0xFFB74B3B);
      return Container(margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [CircleAvatar(backgroundColor: const Color(0xFF34504C), child: Text((barber['ownerName'] as String? ?? 'B').split(' ').map((s) => s.isEmpty ? '' : s[0]).take(2).join().toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(barber['shop'] as String? ?? 'Shop', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)), Text('${barber['ownerName']} · ${barber['phone'] ?? ''}', style: TextStyle(color: muted, fontSize: 11))])), IconButton(tooltip: 'Edit barber details', onPressed: () => editManagedBarber(barber), icon: const Icon(Icons.edit_outlined, size: 19, color: ink)), Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 9))]),
        if (pending) ...[const SizedBox(height: 11), Row(children: [Expanded(child: OutlinedButton(onPressed: () => reviewBarber(barber['id'] as String, 'reject'), style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB74B3B)), child: const Text('Reject'))), const SizedBox(width: 8), Expanded(child: FilledButton(onPressed: () => reviewBarber(barber['id'] as String, 'approve'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF258246)), child: const Text('Approve & enable login')))])],
      ]));
    }),
  ]);

  Widget adminBookings() => ListView(padding: const EdgeInsets.all(20), children: [
    Row(children: [const Expanded(child: Text('Booking management', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800))), IconButton(tooltip: 'Refresh bookings', onPressed: refreshData, icon: const Icon(Icons.refresh_rounded))]),
    const SizedBox(height: 4), Text('Every barber’s customer appointments · live updates about every 8 seconds.', style: TextStyle(color: muted, fontSize: 12)), const SizedBox(height: 16),
    Row(children: [Expanded(child: metricCard('Today', '${remoteBookings.whereType<Map>().where((b) => b['date'] == DateTime.now().toIso8601String().substring(0, 10)).length}', Icons.today_outlined, const Color(0xFFE7F0FA))), const SizedBox(width: 10), Expanded(child: metricCard('This month', '${remoteBookings.whereType<Map>().where((b) => (b['date'] as String? ?? '').startsWith('${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}')).length}', Icons.date_range_outlined, const Color(0xFFE5F4E9)))]), const SizedBox(height: 16),
    const Text('Filter bookings', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)), const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 4, children: [
      ChoiceChip(label: const Text('All'), selected: adminBookingRange == 0, onSelected: (_) => setState(() => adminBookingRange = 0)),
      ChoiceChip(label: const Text('Daily'), selected: adminBookingRange == 1, onSelected: (_) => setState(() => adminBookingRange = 1)),
      ChoiceChip(label: const Text('Monthly'), selected: adminBookingRange == 2, onSelected: (_) => setState(() => adminBookingRange = 2)),
    ]),
    if (adminBookingRange != 0) ...[
      const SizedBox(height: 6),
      OutlinedButton.icon(onPressed: chooseAdminBookingDate, icon: const Icon(Icons.calendar_month_outlined), label: Text(adminBookingRange == 1 ? 'Date: ${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}-${adminBookingDate.day.toString().padLeft(2, '0')}' : 'Month: ${adminBookingDate.year}-${adminBookingDate.month.toString().padLeft(2, '0')}')),
    ],
    const SizedBox(height: 8),
    SizedBox(height: 46, child: FilledButton.icon(onPressed: exportAdminBookings, style: FilledButton.styleFrom(backgroundColor: ink), icon: const Icon(Icons.file_download_outlined), label: const Text('Export booking details as CSV'))),
    const SizedBox(height: 18),
    Text('Bookings (${filteredAdminBookings.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height: 9),
    if (filteredAdminBookings.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 25), child: Text(remoteBookings.isEmpty ? 'No bookings yet.' : 'No bookings match this date range.', style: TextStyle(color: muted, fontSize: 12)))
    else ...filteredAdminBookings.map(bookingCard),
  ]);

  Widget metricCard(String label, String value, IconData icon, Color tint) => Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(width: 33, height: 33, decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 17, color: ink)), const SizedBox(height: 11), Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)), const SizedBox(height: 2), Text(label, style: TextStyle(color: muted, fontSize: 10))]));

  Widget portalAppointment(String time, String customer, String service, String status) => Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)), child: Row(children: [Container(width: 58, padding: const EdgeInsets.symmetric(vertical: 7), decoration: BoxDecoration(color: paper, borderRadius: BorderRadius.circular(9)), child: Text(time, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10))), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(customer, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), Text(service, style: TextStyle(color: muted, fontSize: 10))])), Text(status, style: TextStyle(color: status == 'Pending' ? const Color(0xFFAD7720) : const Color(0xFF258246), fontSize: 10, fontWeight: FontWeight.bold))]));

  Widget portalRow(IconData icon, String title, String subtitle, {VoidCallback? onTap}) => Material(color: Colors.white, borderRadius: BorderRadius.circular(14), child: ListTile(onTap: onTap, contentPadding: const EdgeInsets.symmetric(horizontal: 12), leading: Icon(icon, color: const Color(0xFFAD7A29)), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), subtitle: Text(subtitle, style: TextStyle(color: muted, fontSize: 10)), trailing: const Icon(Icons.chevron_right_rounded, color: muted)));
}

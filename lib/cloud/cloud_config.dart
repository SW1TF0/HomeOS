import 'firebase.dart';

/// The app's Firebase project (homeos-b9e5e), where accounts and their homes
/// are kept. The API key and the database address only say which project to
/// talk to; they are meant to ship inside the app. Who may read or write what
/// is decided by the database rules in firebase/database.rules.json.
const firebaseConfig = FirebaseConfig(
  apiKey: String.fromEnvironment('FIREBASE_API_KEY', defaultValue: 'AIzaSyCHZMIxIOS0olZ9JtT65P33khAP3h-ltoQ'),
  databaseUrl: String.fromEnvironment(
    'FIREBASE_DATABASE_URL',
    defaultValue: 'https://homeos-b9e5e-default-rtdb.europe-west1.firebasedatabase.app',
  ),
);

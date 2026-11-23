import 'firebase.dart';

/// The app's Firebase project (homeos-b9e5e), where accounts and their homes
/// are kept. Who may read or write what is decided by the database rules in
/// firebase/database.rules.json.
///
/// The API key is not kept in the code. It is given when the app is built:
/// GitHub's Build apps takes it from the FIREBASE_API_KEY repository secret,
/// and ./flutterw takes it from firebase.local.json (not in git; copy
/// firebase.local.example.json). Without it the app works as before, with no
/// account and no cloud.
const firebaseConfig = FirebaseConfig(
  apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
  databaseUrl: String.fromEnvironment(
    'FIREBASE_DATABASE_URL',
    defaultValue: 'https://homeos-b9e5e-default-rtdb.europe-west1.firebasedatabase.app',
  ),
);

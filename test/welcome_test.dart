import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/cloud/cloud_sync.dart';
import 'package:smartmenukj/cloud/memory_cloud.dart';
import 'package:smartmenukj/l10n/text.dart' as l10n;
import 'package:smartmenukj/state/app_settings.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/ui/screens/auth_screen.dart';
import 'package:smartmenukj/ui/screens/home_screen.dart';
import 'package:smartmenukj/ui/widgets/motion.dart';

Future<HomeStore> newStore() async {
  final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
  await store.load();
  return store;
}

/// The app as it opens on a phone: with its opening and, the first time, the welcome screens.
Future<HomeStore> openApp(WidgetTester tester, {AppSettings? settings, CloudSync? cloud, HomeStore? store}) async {
  tester.view.physicalSize = const Size(420, 900) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  store ??= await newStore();
  await tester.pumpWidget(SmartMenuApp(store: store, cloud: cloud, settings: settings, poll: false, intro: true));
  await tester.pump();
  return store;
}

/// Lets the motion run on, as in the real app, for one test.
void withMotion() {
  Motion.allowed = true;
  addTearDown(() {
    Motion.allowed = false;
    Motion.revealed.value = true;
  });
}

String fieldText(WidgetTester tester, String key) =>
    tester.widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText))).controller.text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a new install opens on the welcome, turns its pages, keeps the name and greets by it', (tester) async {
    final settings = AppSettings();
    await openApp(tester, settings: settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome')), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(find.text('Every device, one app'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-next')));
    await tester.pumpAndSettle();
    expect(find.text('Draw your home'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-next')));
    await tester.pumpAndSettle();
    expect(find.text('Control it from anywhere'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-next')));
    await tester.pumpAndSettle();
    expect(find.text('Make it yours'), findsOneWidget);
    expect(find.byKey(const Key('welcome-next')), findsNothing, reason: 'the last page has its own buttons');
    expect(find.byKey(const Key('welcome-create')), findsNothing, reason: 'no accounts on this build');

    await tester.enterText(find.byKey(const Key('welcome-name')), '  Krasimir Ivanov ');
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pumpAndSettle();
    expect(settings.welcomed, isTrue);
    expect(settings.name, 'Krasimir Ivanov');
    expect(find.byKey(const Key('welcome')), findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
    final greeting = tester.widget<l10n.Text>(find.byKey(const Key('home-greeting')));
    expect(greeting.data, matches(RegExp(r'^Good (morning|afternoon|evening|night), Krasimir$')));

    // Once gone through, the app opens on the home.
    final again = AppSettings();
    await again.load();
    expect(again.welcomed, isTrue);
    expect(again.name, 'Krasimir Ivanov');
    await openApp(tester, settings: again);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome')), findsNothing);
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);
  });

  testWidgets('without a name there is no greeting, and the welcome can be skipped', (tester) async {
    final settings = AppSettings();
    await openApp(tester, settings: settings);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await tester.pumpAndSettle();
    expect(find.text('Make it yours'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pumpAndSettle();
    expect(settings.welcomed, isTrue);
    expect(settings.name, '');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('home-greeting')), findsNothing);
  });

  testWidgets('an account made from the welcome takes the name, confirms the email, and comes with it elsewhere',
      (tester) async {
    final memory = MemoryCloud();
    final store = await newStore();
    final cloud = CloudSync(store: store, api: memory.app(), delay: const Duration(milliseconds: 10), storageKey: 'w');
    await cloud.start();
    final settings = AppSettings();
    await openApp(tester, settings: settings, cloud: cloud, store: store);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome-create')), findsOneWidget);
    expect(find.byKey(const Key('welcome-sign-in')), findsOneWidget);
    expect(find.text('Continue without an account'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('welcome-name')), 'Krasimir');
    await tester.tap(find.byKey(const Key('welcome-create')));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(fieldText(tester, 'auth-name'), 'Krasimir', reason: 'the name from the welcome is filled in');
    expect(find.byKey(const Key('auth-strength')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('account-email')), 'k@example.com');
    await tester.enterText(find.byKey(const Key('account-password')), 'Garden-gate-42');
    await tester.pump();
    expect(find.text('Strong'), findsOneWidget);
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(cloud.signedIn, isTrue);
    expect(cloud.account!.name, 'Krasimir');
    expect(memory.names.values, ['Krasimir']);
    expect(memory.emailChecks, ['k@example.com'], reason: 'a link to confirm the address is sent');
    expect(settings.welcomed, isTrue);
    expect(settings.name, 'Krasimir');
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(const Key('auth-submit')), findsNothing);

    // Signing in on another phone brings the name along.
    final store2 = await newStore();
    final cloud2 = CloudSync(store: store2, api: memory.app(), delay: const Duration(milliseconds: 10), storageKey: 'w2');
    await cloud2.start();
    final settings2 = AppSettings();
    await openApp(tester, settings: settings2, cloud: cloud2, store: store2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome-sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const Key('auth-name')), findsNothing);
    expect(find.byKey(const Key('auth-strength')), findsNothing);
    await tester.enterText(find.byKey(const Key('account-email')), 'k@example.com');
    await tester.enterText(find.byKey(const Key('account-password')), 'Garden-gate-42');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(cloud2.signedIn, isTrue);
    expect(settings2.name, 'Krasimir');
    expect(settings2.welcomed, isTrue);
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);
    expect(memory.emailChecks, hasLength(1), reason: 'signing in sends no new link');
    cloud.dispose();
    cloud2.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the sign-in screen shakes off what is wrong, sends a reset link, shows the password and closes',
      (tester) async {
    final store = await newStore();
    final cloud = CloudSync(store: store, api: MemoryCloud().app(), delay: const Duration(milliseconds: 10), storageKey: 'w');
    await cloud.start();
    await openApp(tester, settings: AppSettings()..welcomed = true, cloud: cloud, store: store);
    await tester.pumpAndSettle();
    bool? result;
    openAuth(tester.element(find.byType(HomeScreen))).then((ok) => result = ok);
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('account-email')), 'not an address');
    await tester.enterText(find.byKey(const Key('account-password')), 'secret1');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(find.text('That is not an email address.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('account-email')), 'nobody@example.com');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Wrong email or password.'), findsOneWidget);
    expect(cloud.signedIn, isFalse);

    await tester.tap(find.byKey(const Key('auth-forgot')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-error')), findsNothing);
    expect(find.text('Check your email for a link to set a new password.'), findsOneWidget);

    EditableText password() => tester.widget<EditableText>(
        find.descendant(of: find.byKey(const Key('account-password')), matching: find.byType(EditableText)));
    expect(password().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('auth-show-password')));
    await tester.pump();
    expect(password().obscureText, isFalse);

    await tester.tap(find.byKey(const Key('auth-mode-create')));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.byKey(const Key('auth-name')), findsOneWidget);
    await tester.tap(find.byKey(const Key('auth-mode-signin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-name')), findsNothing);

    await tester.tap(find.byKey(const Key('auth-close')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byKey(const Key('auth-submit')), findsNothing);
    cloud.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  test('the password meter grows with length and kinds of characters', () {
    expect(passwordStrength(''), 0);
    expect(passwordStrength('abc12'), 0, reason: 'too short to be used at all');
    expect(passwordStrength('abcdef'), 1);
    expect(passwordStrength('abcdef12'), 2);
    expect(passwordStrength('Abcdefgh12'), 3);
    expect(passwordStrength('Abcdefghij12'), 4);
    expect(passwordStrength('a' * 16), 4, reason: 'a long phrase is strong by itself');
  });

  testWidgets('the opening animation plays over the app, then lets it through', (tester) async {
    withMotion();
    final settings = AppSettings()..welcomed = true;
    await openApp(tester, settings: settings);
    expect(find.byKey(const Key('launch-curtain')), findsOneWidget);
    expect(Motion.revealed.value, isFalse, reason: 'what glides in waits for the door to open');
    expect(find.byType(HomeScreen), findsOneWidget, reason: 'the app is already there underneath');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(Motion.revealed.value, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(Motion.revealed.value, isTrue, reason: 'the door opened');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.byKey(const Key('launch-curtain')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsOneWidget);
  });

  testWidgets('a tap opens the door at once', (tester) async {
    withMotion();
    await openApp(tester, settings: AppSettings()..welcomed = true);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('launch-curtain')), warnIfMissed: false);
    await tester.pump();
    expect(Motion.revealed.value, isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.byKey(const Key('launch-curtain')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('with Animations off there is no opening animation', (tester) async {
    withMotion();
    await openApp(tester, settings: AppSettings()
      ..welcomed = true
      ..animations = false);
    expect(find.byKey(const Key('launch-curtain')), findsNothing);
    expect(Motion.revealed.value, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('with motion on, the welcome moves, turns its pages and opens the app', (tester) async {
    withMotion();
    final settings = AppSettings();
    await openApp(tester, settings: settings);
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pump();
    expect(find.byKey(const Key('launch-curtain')), findsNothing);
    expect(find.byKey(const Key('welcome')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('Every device, one app'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('Draw your home'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.enterText(find.byKey(const Key('welcome-name')), 'Krasimir');
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome')), findsNothing);
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);
    expect(settings.welcomed, isTrue);
  });

  testWidgets('Settings sets the name, turns animations off and shows the welcome again', (tester) async {
    final settings = AppSettings()..welcomed = true;
    await openApp(tester, settings: settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-greeting')), findsNothing);
    await tester.tap(find.byKey(const Key('profile-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Not given. The home screen greets you by it.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-name')));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'Mila');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(settings.name, 'Mila');
    expect(find.descendant(of: find.byKey(const Key('settings-name')), matching: find.text('Mila')), findsOneWidget);

    expect(settings.animations, isTrue);
    await tester.tap(find.byKey(const Key('settings-animations')));
    await tester.pumpAndSettle();
    expect(settings.animations, isFalse);
    final kept = AppSettings();
    await kept.load();
    expect(kept.animations, isFalse);
    expect(kept.name, 'Mila');

    final list = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const Key('settings-welcome')), 300, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-welcome')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome')), findsOneWidget);
    expect(find.text('Every device, one app'), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-skip')));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'welcome-name'), 'Mila', reason: 'the name already given');
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome')), findsNothing);
    expect(find.text('Settings'), findsOneWidget, reason: 'back where it was opened from');

    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
    expect(tester.widget<l10n.Text>(find.byKey(const Key('home-greeting'))).data, endsWith(', Mila'));
  });
}

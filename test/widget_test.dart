import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_jira_timetac/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Timetac + Outlook → Jira Worklogs'), findsOneWidget);
  });
}

// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Lares';

  @override
  String get commonCancel => 'Never mind';

  @override
  String get commonConfirm => 'OK';

  @override
  String get commonDone => 'Done';

  @override
  String get homeAddCircle => 'New circle';

  @override
  String get homeAddCircleHint => 'Family, close friends, study group…';

  @override
  String get homePasteInvite => 'Have an invite link? Paste it';

  @override
  String homeKickedBy(String who) {
    return '$who removed you from the room';
  }

  @override
  String get homeKickedByAdmin => 'An admin';
}
